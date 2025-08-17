package main

// png-to-text-tesseract: Parallel PNG → text via Tesseract with cleaning; replaces scripts/png_to_text_tesseract.sh

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"book-expert/internal/config"
	"book-expert/internal/logging"
)

// Precompiled cleanup utilities for high performance
var (
	// Join hyphenated line breaks like "infor-\n mation" -> "information"
	reHyphenJoin = regexp.MustCompile(`([a-z])-\s*\n\s*([a-z])`)

	// Remove tokens like Preprint / preprints with optional trailing apostrophes
	rePreprintToken = regexp.MustCompile(`(?i)\bpreprints?\b['’]*`)

	// Remove diacritic detection notices
	reDetectedDiacriticsToken = regexp.MustCompile(`(?i)\bdetected\s+\d+\s+diacritics\b`)

	// Remove noisy Tesseract phrases
	reNoBestWordsToken = regexp.MustCompile(`(?i)no\s+best\s+words!+`)

	// Lines that are only punctuation/space
	rePunctOnlyLine = regexp.MustCompile(`^\s*[\p{P}\s]+\s*$`)

	// Collapse multiple spaces
	reMultiSpace = regexp.MustCompile(`[ \t]{2,}`)
)

var charReplacer = strings.NewReplacer(
	// Common ligatures
	"ﬁ", "fi",
	"ﬂ", "fl",
	"ﬀ", "ff",
	"ﬃ", "ffi",
	"ﬄ", "ffl",
	// Dashes and ellipsis
	"—", "--",
	"–", "--",
	"…", "...",
	// Carriage returns
	"\r", "",
)

type task struct {
	pngPath   string
	outputDir string
}

func main() {
	start := time.Now()
	root, cfgPath, err := config.FindProjectRoot(mustGetwd())
	if err != nil {
		fatal("find root: %v", err)
	}
	cfg, err := config.Load(cfgPath)
	if err != nil {
		fatal("load config: %v", err)
	}

	logDir := cfg.LogsDir.PNGToText
	if logDir == "" {
		logDir = filepath.Join(root, "logs", "png_to_text")
	}
	logger, err := logging.New(logDir, fmt.Sprintf("log_%s.log", time.Now().Format("20060102_150405")))
	if err != nil {
		fatal("logger: %v", err)
	}
	defer logger.Close()

	inputDir := cfg.Paths.InputDir
	outputDir := cfg.Paths.OutputDir
	if inputDir == "" || outputDir == "" {
		fatal("missing paths.input_dir or paths.output_dir")
	}

	workers := cfg.Settings.Workers
	if workers <= 0 {
		workers = runtime.NumCPU()
	}
	if workers > 64 {
		workers = 64
	} // safety cap

	dpi := cfg.Settings.DPI
	if dpi <= 0 {
		dpi = 300
	}

	logger.Info("PNG->Text start: input=%s output=%s workers=%d dpi=%d", inputDir, outputDir, workers, dpi)

	// Discover all PNG directories for each PDF project
	dirs, err := discoverPNGDirs(inputDir, outputDir)
	if err != nil {
		fatal("discover: %v", err)
	}
	if len(dirs) == 0 {
		logger.Error("No PNG directories found")
		os.Exit(1)
	}

	for _, pngDir := range dirs {
		pdfName := filepath.Base(filepath.Dir(pngDir))
		textDir := filepath.Join(outputDir, pdfName, "text")
		if err := processOneDir(logger, pngDir, textDir, workers, dpi, cfg, root); err != nil {
			logger.Error("Failed directory %s: %v", pngDir, err)
		} else {
			logger.Success("Completed %s", pngDir)
		}
	}

	logger.Success("All done in %s", time.Since(start))
}

func processOneDir(logger *logging.Logger, pngDir, textDir string, workers int, dpi int, cfg config.Config, projectRoot string) error {
	if err := os.MkdirAll(textDir, 0o755); err != nil {
		return err
	}
	pngs, err := findPNGsSorted(pngDir)
	if err != nil {
		return err
	}
	if len(pngs) == 0 {
		return fmt.Errorf("no pngs in %s", pngDir)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	jobs := make(chan task, workers*4)
	var wg sync.WaitGroup

	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for t := range jobs {
				if err := ocrOne(ctx, logger, t.pngPath, textDir, dpi, cfg, projectRoot); err != nil {
					logger.Warn("ocr failed: %s: %v", filepath.Base(t.pngPath), err)
				}
			}
		}()
	}

	for _, p := range pngs {
		jobs <- task{pngPath: p, outputDir: textDir}
	}
	close(jobs)
	wg.Wait()
	return nil
}

func ocrOne(ctx context.Context, logger *logging.Logger, pngPath, outDir string, dpi int, cfg config.Config, projectRoot string) error {
	base := strings.TrimSuffix(filepath.Base(pngPath), ".png")
	out := filepath.Join(outDir, base+".txt")
	// Ensure output directory exists to avoid write errors in workers
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return fmt.Errorf("ensure out dir: %w", err)
	}
	if fi, err := os.Stat(out); err == nil && fi.Size() > 0 {
		return nil
	}

	// Build tesseract args from config
	lang := cfg.Tesseract.Language
	if strings.TrimSpace(lang) == "" {
		lang = "eng+equ"
	}
	oem := cfg.Tesseract.OEM
	if oem == 0 {
		oem = 3
	}
	psm := cfg.Tesseract.PSM
	if psm == 0 {
		psm = 3
	}

	// tesseract to stdout; limit internal threads to 1 to avoid oversubscription when running many workers
	tctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	var stdout, stderr bytes.Buffer
	cmd := exec.CommandContext(tctx, "tesseract",
		pngPath, "stdout",
		"-l", lang,
		"--dpi", fmt.Sprintf("%d", dpi),
		"--oem", strconv.Itoa(oem),
		"--psm", strconv.Itoa(psm),
	)
	cmd.Env = append(os.Environ(), "OMP_NUM_THREADS=1", "OPENBLAS_NUM_THREADS=1", "MKL_NUM_THREADS=1", "NUMEXPR_NUM_THREADS=1")
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		// Retry once with a more permissive psm if timeout or transient error
		if tctx.Err() == context.DeadlineExceeded {
			logger.Warn("tesseract timed out for %s; retrying with psm=6", filepath.Base(pngPath))
			retryCtx, cancel := context.WithTimeout(ctx, 2*time.Minute)
			defer cancel()
			var rOut, rErr bytes.Buffer
			retry := exec.CommandContext(retryCtx, "tesseract",
				pngPath, "stdout",
				"-l", lang,
				"--dpi", fmt.Sprintf("%d", dpi),
				"--oem", strconv.Itoa(oem),
				"--psm", "6",
			)
			retry.Env = cmd.Env
			retry.Stdout = &rOut
			retry.Stderr = &rErr
			if err2 := retry.Run(); err2 == nil {
				stdout = rOut
				stderr = rErr
			} else {
				return fmt.Errorf("tesseract retry: %v: %s", err2, rErr.String())
			}
		} else {
			return fmt.Errorf("tesseract: %v: %s", err, stderr.String())
		}
	}
	text := stdout.String()
	if strings.TrimSpace(text) == "" {
		return fmt.Errorf("empty OCR output")
	}

	// Clean in-process for performance and parallelism
	cleaned := cleanOCROutput(text)
	if strings.TrimSpace(cleaned) == "" {
		cleaned = text
	}
	return os.WriteFile(out, []byte(cleaned), 0o644)
}

// cleanOCROutput applies fast, safe, deterministic cleanup suitable for parallel execution.
func cleanOCROutput(in string) string {
	if in == "" {
		return in
	}

	// 1) Cheap character-level replacements
	s := charReplacer.Replace(in)

	// 2) Remove obvious Tesseract artifacts (case-insensitive)
	s = rePreprintToken.ReplaceAllString(s, "")
	s = reDetectedDiacriticsToken.ReplaceAllString(s, "")
	s = reNoBestWordsToken.ReplaceAllString(s, "")

	// 3) Fix hyphenated line breaks across lines
	s = reHyphenJoin.ReplaceAllString(s, "$1$2")

	// 4) Normalize whitespace line-by-line and drop punct-only lines
	var b strings.Builder
	b.Grow(len(s))
	scanner := bufio.NewScanner(strings.NewReader(s))
	// Increase scanner buffer to handle long lines
	const maxLine = 1024 * 1024
	buf := make([]byte, 0, 64*1024)
	scanner.Buffer(buf, maxLine)
	first := true
	for scanner.Scan() {
		line := scanner.Text()
		line = strings.TrimSpace(line)
		if line == "" || rePunctOnlyLine.MatchString(line) {
			continue
		}
		line = reMultiSpace.ReplaceAllString(line, " ")
		if !first {
			b.WriteByte('\n')
		}
		first = false
		b.WriteString(line)
	}
	if err := scanner.Err(); err == nil {
		s = b.String()
	}

	return strings.TrimSpace(s)
}

func discoverPNGDirs(inputDir, outputDir string) ([]string, error) {
	// For each pdf in inputDir, expect outputDir/<pdf>/png
	pdfs, err := listPDFBaseNames(inputDir)
	if err != nil {
		return nil, err
	}
	var dirs []string
	for _, p := range pdfs {
		d := filepath.Join(outputDir, p, "png")
		if st, err := os.Stat(d); err == nil && st.IsDir() {
			dirs = append(dirs, d)
		}
	}
	return dirs, nil
}

func listPDFBaseNames(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var out []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if strings.HasSuffix(strings.ToLower(name), ".pdf") {
			out = append(out, strings.TrimSuffix(name, ".pdf"))
		}
	}
	return out, nil
}

func findPNGsSorted(dir string) ([]string, error) {
	f, err := os.Open(dir)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var pngs []string
	s := bufio.NewScanner(f)
	// Fallback to os.ReadDir because listing via Scanner on directory won't work; use ReadDir then sort.
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	_ = s // avoid unused in case of future streaming impl
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if strings.HasSuffix(strings.ToLower(name), ".png") {
			pngs = append(pngs, filepath.Join(dir, name))
		}
	}
	sort.Strings(pngs)
	return pngs, nil
}

func mustGetwd() string {
	wd, err := os.Getwd()
	if err != nil {
		panic(err)
	}
	return wd
}
func fatal(format string, args ...any) { fmt.Fprintf(os.Stderr, format+"\n", args...); os.Exit(1) }
