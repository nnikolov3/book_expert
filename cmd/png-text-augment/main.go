package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"book-expert/internal/config"
	"book-expert/internal/logging"
)

// Gemini API request/response models (minimal subset used)
type geminiInlineData struct {
	MimeType string `json:"mimeType"`
	Data     string `json:"data"`
}

type geminiPart struct {
	Text       string            `json:"text,omitempty"`
	InlineData *geminiInlineData `json:"inlineData,omitempty"`
}

type geminiContent struct {
	Role  string       `json:"role,omitempty"`
	Parts []geminiPart `json:"parts"`
}

type geminiGenerationConfig struct {
	Temperature     float64 `json:"temperature"`
	TopK            int     `json:"topK"`
	TopP            float64 `json:"topP"`
	MaxOutputTokens int     `json:"maxOutputTokens"`
}

type geminiRequest struct {
	Contents         []geminiContent        `json:"contents"`
	GenerationConfig geminiGenerationConfig `json:"generationConfig"`
}

type geminiCandidateContentPart struct {
	Text string `json:"text"`
}

type geminiCandidateContent struct {
	Parts []geminiCandidateContentPart `json:"parts"`
}

type geminiCandidate struct {
	Content geminiCandidateContent `json:"content"`
}

type geminiError struct {
	Message string `json:"message"`
}

type geminiResponse struct {
	Candidates []geminiCandidate `json:"candidates"`
	Error      *geminiError      `json:"error,omitempty"`
}

// Default model order: prefer the lighter models first
var defaultModelFallback = []string{
	"gemini-2.5-flash-lite",
	"gemini-2.5-flash",
	"gemini-2.5-pro",
}

// augmentationPromptHeader will be loaded from project.toml if available; this is a safe fallback.
const augmentationPromptHeader = `You are a PhD-level technical narrator. Integrate commentary derived from the page image into the OCR text, producing a coherent narration for text-to-speech. Maintain technical accuracy, describe figures/code/tables as natural prose inserted near the relevant context, avoid markdown, and output continuous paragraphs.`

type pagePair struct {
	baseName  string
	textPath  string
	imagePath string
}

type runContext struct {
	cfg           config.Config
	logger        *logging.Logger
	apiKey        string
	modelOrder    []string
	maxRetries    int
	retryDelay    time.Duration
	timeoutPerReq time.Duration
	client        *http.Client
	workers       int
	limitPages    int
	promptText    string
	projectRoot   string
}

func main() {
	// Flags
	var bookDirFlag string
	var modelFlag string
	var workersFlag int
	var timeoutSecondsFlag int
	var limitPages int
	flag.StringVar(&bookDirFlag, "book-dir", "", "Absolute path to the book directory containing 'text/' and 'png/' (optional if PDFs exist in paths.input_dir)")
	flag.StringVar(&modelFlag, "model", "", "Override Gemini model (default uses lightweight fallback order)")
	flag.IntVar(&workersFlag, "workers", 4, "Number of concurrent workers for page processing")
	flag.IntVar(&timeoutSecondsFlag, "timeout", 120, "Per-request timeout in seconds")
	flag.IntVar(&limitPages, "limit", 0, "Optional max number of pages to process (0=all)")
	flag.Parse()

	startTime := time.Now()

	// Load project configuration
	projectRoot, projectTomlPath, err := config.FindProjectRoot(mustGetwd())
	if err != nil {
		fatalf("find project root: %v", err)
	}
	cfg, err := config.Load(projectTomlPath)
	if err != nil {
		fatalf("load config: %v", err)
	}

	// Logger
	logDir := cfg.LogsDir.FinalText
	if logDir == "" {
		// Fallback to project-local logs if not set
		logDir = filepath.Join(projectRoot, "logs", "pipeline")
	}
	logFileName := fmt.Sprintf("png_text_augment_%s.log", time.Now().Format("2006-01-02_15-04-05"))
	logger, err := logging.New(logDir, logFileName)
	if err != nil {
		fatalf("init logger: %v", err)
	}
	defer func() { _ = logger.Close() }()

	logger.Info("Project root: %s", projectRoot)

	// Resolve API key
	apiKeyVar := strings.TrimSpace(cfg.GoogleAPI.APIKeyVariable)
	if apiKeyVar == "" {
		logger.Error("google_api.api_key_variable not set in project.toml")
		os.Exit(1)
	}
	apiKey := strings.TrimSpace(os.Getenv(apiKeyVar))
	if apiKey == "" {
		logger.Error("Google API key missing in environment variable %s", apiKeyVar)
		os.Exit(1)
	}

	// Concurrency and timeouts
	if workersFlag <= 0 {
		if cfg.Settings.Workers > 0 {
			workersFlag = cfg.Settings.Workers
		} else {
			workersFlag = 1
		}
	}
	timeoutPerRequest := time.Duration(timeoutSecondsFlag) * time.Second
	client := &http.Client{Timeout: timeoutPerRequest}

	// Model order
	modelOrder := defaultModelFallback
	if modelFlag != "" {
		modelOrder = []string{modelFlag}
	}

	// Retry config
	maxRetries := cfg.GoogleAPI.MaxRetries
	if maxRetries <= 0 {
		maxRetries = 3
	}
	retryDelay := time.Duration(cfg.GoogleAPI.RetryDelaySec)
	if retryDelay <= 0 {
		retryDelay = 30
	}
	retryDelay = retryDelay * time.Second

	// Prompt
	promptText := strings.TrimSpace(cfg.Prompts.ExtractText.Prompt)
	if promptText == "" {
		promptText = augmentationPromptHeader
	}

	run := runContext{
		cfg:           cfg,
		logger:        logger,
		apiKey:        apiKey,
		modelOrder:    modelOrder,
		maxRetries:    maxRetries,
		retryDelay:    retryDelay,
		timeoutPerReq: timeoutPerRequest,
		client:        client,
		workers:       workersFlag,
		limitPages:    limitPages,
		promptText:    promptText,
		projectRoot:   projectRoot,
	}

	// Determine target book directories
	var bookDirs []string
	if strings.TrimSpace(bookDirFlag) != "" {
		bd := bookDirFlag
		if !filepath.IsAbs(bd) {
			abs, abserr := filepath.Abs(bd)
			if abserr != nil {
				logger.Error("resolve book-dir: %v", abserr)
				os.Exit(1)
			}
			bd = abs
		}
		bookDirs = []string{bd}
	} else {
		// Auto-discover PDFs in paths.input_dir, derive book dirs in paths.output_dir/<pdf_basename>
		inputDir := strings.TrimSpace(cfg.Paths.InputDir)
		outputDir := strings.TrimSpace(cfg.Paths.OutputDir)
		if inputDir == "" || outputDir == "" {
			logger.Error("paths.input_dir or paths.output_dir missing in project.toml")
			os.Exit(1)
		}
		pdfs, err := findPDFs(inputDir)
		if err != nil {
			logger.Error("find PDFs: %v", err)
			os.Exit(1)
		}
		if len(pdfs) == 0 {
			logger.Error("No PDFs found under %s", inputDir)
			os.Exit(1)
		}
		for _, pdf := range pdfs {
			name := strings.TrimSuffix(filepath.Base(pdf), filepath.Ext(pdf))
			bd := filepath.Join(outputDir, name)
			bookDirs = append(bookDirs, bd)
		}
	}

	// Process each derived book directory
	var hadAnyError bool
	for _, bd := range bookDirs {
		if err := processOneBook(run, bd); err != nil {
			hadAnyError = true
			run.logger.Error("%v", err)
		}
	}

	if hadAnyError {
		run.logger.Warn("One or more books failed during augmentation")
	}
	run.logger.Info("Elapsed total: %s", time.Since(startTime))
}

func processOneBook(run runContext, bookDir string) error {
	textDir := filepath.Join(bookDir, "text")
	pngDir := filepath.Join(bookDir, "png")
	outputPagesDir := filepath.Join(bookDir, "final_text")
	outputFinalDir := filepath.Join(bookDir, "final_complete")
	outputFinalFile := filepath.Join(outputFinalDir, "final_text.txt")

	run.logger.Info("Book dir: %s", bookDir)
	run.logger.Info("Text dir: %s", textDir)
	run.logger.Info("PNG dir: %s", pngDir)

	// Validate dirs
	if err := ensureDir(textDir); err != nil {
		return fmt.Errorf("text dir error: %w", err)
	}
	if err := ensureDir(pngDir); err != nil {
		return fmt.Errorf("png dir error: %w", err)
	}
	if err := os.MkdirAll(outputPagesDir, 0o755); err != nil {
		return fmt.Errorf("create output pages dir: %w", err)
	}
	if err := os.MkdirAll(outputFinalDir, 0o755); err != nil {
		return fmt.Errorf("create output final dir: %w", err)
	}

	// Build page pairs
	pairs, err := findPagePairs(textDir, pngDir)
	if err != nil {
		return fmt.Errorf("pairing pages: %w", err)
	}
	if len(pairs) == 0 {
		return fmt.Errorf("no page pairs found in %s and %s", textDir, pngDir)
	}

	// Sort by numeric suffix when present, else by basename
	sortPairsInDocumentOrder(pairs)
	if run.limitPages > 0 && run.limitPages < len(pairs) {
		pairs = pairs[:run.limitPages]
	}

	run.logger.Info("Starting augmentation for %d pages with %d workers", len(pairs), run.workers)

	jobs := make(chan int)
	resultErrors := make(chan error, len(pairs))
	type result struct {
		index int
		name  string
		text  string
	}
	results := make([]result, len(pairs))

	for w := 0; w < run.workers; w++ {
		go func(workerID int) {
			for idx := range jobs {
				p := pairs[idx]
				augmented, augErr := augmentPage(context.Background(), run.client, run.apiKey, run.modelOrder, run.maxRetries, run.retryDelay, p, run.promptText)
				if augErr != nil {
					resultErrors <- fmt.Errorf("page %s: %w", p.baseName, augErr)
					continue
				}

				// Write per-page output
				pageOutPath := filepath.Join(outputPagesDir, p.baseName+".txt")
				if writeErr := os.WriteFile(pageOutPath, []byte(augmented), 0o644); writeErr != nil {
					resultErrors <- fmt.Errorf("write page output %s: %w", pageOutPath, writeErr)
					continue
				}

				results[idx] = result{index: idx, name: p.baseName, text: augmented}
				resultErrors <- nil
			}
		}(w)
	}

	for i := range pairs {
		jobs <- i
	}
	close(jobs)

	// Await all results
	var hadError bool
	for i := 0; i < len(pairs); i++ {
		if err := <-resultErrors; err != nil {
			run.logger.Error("%v", err)
			hadError = true
		}
	}

	if hadError {
		run.logger.Warn("Completed with some errors; continuing to concatenation of successful pages")
	}

	// Concatenate in order
	var builder strings.Builder
	for i := 0; i < len(results); i++ {
		if results[i].text == "" {
			continue
		}
		if builder.Len() > 0 {
			builder.WriteString("\n\n")
		}
		builder.WriteString(results[i].text)
	}
	if err := os.WriteFile(outputFinalFile, []byte(builder.String()), 0o644); err != nil {
		return fmt.Errorf("write final file %s: %w", outputFinalFile, err)
	}

	run.logger.Success("Augmentation complete. Final narration: %s", outputFinalFile)
	return nil
}

func findPDFs(root string) ([]string, error) {
	var pdfs []string
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		lower := strings.ToLower(d.Name())
		if strings.HasSuffix(lower, ".pdf") {
			pdfs = append(pdfs, path)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	// deterministic order
	sort.Strings(pdfs)
	return pdfs, nil
}

func mustGetwd() string {
	wd, err := os.Getwd()
	if err != nil {
		panic(err)
	}
	return wd
}

func ensureDir(path string) error {
	st, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("stat %s: %w", path, err)
	}
	if !st.IsDir() {
		return fmt.Errorf("%s is not a directory", path)
	}
	return nil
}

func findPagePairs(textDir, pngDir string) ([]pagePair, error) {
	textEntries, err := os.ReadDir(textDir)
	if err != nil {
		return nil, fmt.Errorf("read text dir: %w", err)
	}
	pngEntries, err := os.ReadDir(pngDir)
	if err != nil {
		return nil, fmt.Errorf("read png dir: %w", err)
	}

	textMap := make(map[string]string)
	for _, de := range textEntries {
		if de.IsDir() {
			continue
		}
		name := de.Name()
		if strings.HasSuffix(strings.ToLower(name), ".txt") {
			base := strings.TrimSuffix(name, filepath.Ext(name))
			textMap[base] = filepath.Join(textDir, name)
		}
	}

	pngMap := make(map[string]string)
	for _, de := range pngEntries {
		if de.IsDir() {
			continue
		}
		name := de.Name()
		lower := strings.ToLower(name)
		if strings.HasSuffix(lower, ".png") || strings.HasSuffix(lower, ".jpg") || strings.HasSuffix(lower, ".jpeg") {
			base := strings.TrimSuffix(name, filepath.Ext(name))
			pngMap[base] = filepath.Join(pngDir, name)
		}
	}

	var bases []string
	for base := range textMap {
		if _, ok := pngMap[base]; ok {
			bases = append(bases, base)
		}
	}
	if len(bases) == 0 {
		return nil, nil
	}

	sort.Strings(bases)
	pairs := make([]pagePair, 0, len(bases))
	for _, base := range bases {
		pairs = append(pairs, pagePair{
			baseName:  base,
			textPath:  textMap[base],
			imagePath: pngMap[base],
		})
	}
	return pairs, nil
}

var pageNumRegex = regexp.MustCompile(`(?i)(?:page[_\-\s]*)(\d+)`)

func sortPairsInDocumentOrder(pairs []pagePair) {
	type sortable struct {
		p    pagePair
		key  string
		num  int
		hasN bool
	}
	items := make([]sortable, 0, len(pairs))
	for _, p := range pairs {
		m := pageNumRegex.FindStringSubmatch(p.baseName)
		if len(m) == 2 {
			// parse numeric component; ignore error by leaving hasN=false on failure
			n := 0
			_, _ = fmt.Sscanf(m[1], "%d", &n)
			items = append(items, sortable{p: p, key: strings.ToLower(p.baseName), num: n, hasN: true})
		} else {
			items = append(items, sortable{p: p, key: strings.ToLower(p.baseName), hasN: false})
		}
	}
	sort.Slice(items, func(i, j int) bool {
		if items[i].hasN && items[j].hasN {
			if items[i].num != items[j].num {
				return items[i].num < items[j].num
			}
			return items[i].key < items[j].key
		}
		if items[i].hasN != items[j].hasN {
			// numeric-first ordering
			return items[i].hasN
		}
		return items[i].key < items[j].key
	})
	for i := range pairs {
		pairs[i] = items[i].p
	}
}

func augmentPage(ctx context.Context, client *http.Client, apiKey string, modelOrder []string, maxRetries int, retryDelay time.Duration, pair pagePair, promptText string) (string, error) {
	// Read text
	ocrBytes, err := os.ReadFile(pair.textPath)
	if err != nil {
		return "", fmt.Errorf("read text %s: %w", pair.textPath, err)
	}
	ocrText := strings.TrimSpace(string(ocrBytes))

	// Read and encode image
	imgBytes, err := os.ReadFile(pair.imagePath)
	if err != nil {
		return "", fmt.Errorf("read image %s: %w", pair.imagePath, err)
	}
	imgB64 := base64.StdEncoding.EncodeToString(imgBytes)
	mimeType := detectImageMimeType(pair.imagePath)

	// Build prompt text
	var userTextBuilder strings.Builder
	if promptText == "" {
		promptText = augmentationPromptHeader
	}
	userTextBuilder.WriteString(promptText)
	userTextBuilder.WriteString("\n\nOCR TEXT FOLLOWS:\n\n")
	if ocrText == "" {
		userTextBuilder.WriteString("[This page contains little or no OCR text. Describe relevant content from the image in clear narration.]")
	} else {
		userTextBuilder.WriteString(ocrText)
	}
	userText := userTextBuilder.String()

	// Try models with retries
	var lastErr error
	for _, model := range modelOrder {
		for attempt := 1; attempt <= maxRetries; attempt++ {
			content := geminiContent{
				Role: "user",
				Parts: []geminiPart{
					{Text: userText},
					{InlineData: &geminiInlineData{MimeType: mimeType, Data: imgB64}},
				},
			}

			reqBody := geminiRequest{
				Contents: []geminiContent{content},
				GenerationConfig: geminiGenerationConfig{
					Temperature:     0.1,
					TopK:            40,
					TopP:            0.95,
					MaxOutputTokens: 8192,
				},
			}
			out, err := callGemini(ctx, client, apiKey, model, reqBody)
			if err == nil && strings.TrimSpace(out) != "" {
				return out, nil
			}
			if err == nil {
				err = errors.New("empty response from model")
			}
			lastErr = fmt.Errorf("model %s attempt %d/%d: %w", model, attempt, maxRetries, err)
			// Retry delay with simple backoff
			time.Sleep(retryDelay)
		}
	}
	if lastErr == nil {
		lastErr = errors.New("augmentation failed with no error detail")
	}
	return "", lastErr
}

func callGemini(ctx context.Context, client *http.Client, apiKey string, model string, body geminiRequest) (string, error) {
	// Build URL
	url := fmt.Sprintf("https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent?key=%s", model, apiKey)

	// Encode JSON
	jsonBytes, err := json.Marshal(body)
	if err != nil {
		return "", fmt.Errorf("marshal request: %w", err)
	}

	// Request
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(jsonBytes))
	if err != nil {
		return "", fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("post to gemini: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	respBytes, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("read response: %w", err)
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		// Try to extract API error message
		var apiErrResp geminiResponse
		if uerr := json.Unmarshal(respBytes, &apiErrResp); uerr == nil && apiErrResp.Error != nil {
			return "", fmt.Errorf("gemini HTTP %d: %s", resp.StatusCode, apiErrResp.Error.Message)
		}
		return "", fmt.Errorf("gemini HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(respBytes)))
	}

	var gresp geminiResponse
	if err := json.Unmarshal(respBytes, &gresp); err != nil {
		return "", fmt.Errorf("decode response: %w", err)
	}
	if gresp.Error != nil && gresp.Error.Message != "" {
		return "", fmt.Errorf("gemini error: %s", gresp.Error.Message)
	}
	if len(gresp.Candidates) == 0 {
		return "", errors.New("no candidates in response")
	}
	// Concatenate parts text from first candidate
	var b strings.Builder
	for _, part := range gresp.Candidates[0].Content.Parts {
		if strings.TrimSpace(part.Text) == "" {
			continue
		}
		if b.Len() > 0 {
			b.WriteString("\n")
		}
		b.WriteString(part.Text)
	}
	return b.String(), nil
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}

// detectImageMimeType returns a reasonable MIME type based on file extension.
// Defaults to image/png when uncertain.
func detectImageMimeType(path string) string {
	ext := strings.ToLower(filepath.Ext(path))
	switch ext {
	case ".png":
		return "image/png"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".webp":
		return "image/webp"
	default:
		return "image/png"
	}
}
