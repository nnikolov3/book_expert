package main

// text-to-wav: Chunk cleaned text and synthesize WAVs via external F5-TTS CLI; replaces scripts/generate_wav.sh

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"book-expert/internal/config"
	"book-expert/internal/logging"
)

func main() {
	root, cfgPath, err := config.FindProjectRoot(mustGetwd())
	if err != nil {
		fatal("find root: %v", err)
	}
	cfg, err := config.Load(cfgPath)
	if err != nil {
		fatal("load config: %v", err)
	}

	logDir := cfg.LogsDir.TextToWav
	if logDir == "" {
		logDir = filepath.Join(root, "logs", "chunks_to_wav")
	}
	logger, err := logging.New(logDir, fmt.Sprintf("log_%s.log", timestamp()))
	if err != nil {
		fatal("logger: %v", err)
	}
	defer logger.Close()

	inputDir := cfg.Paths.InputDir
	outputDir := cfg.Paths.OutputDir
	model := cfg.F5TTSSettings.Model
	if model == "" {
		model = "E2TTS_Base"
	}

	pdfs, err := listPDFBaseNames(inputDir)
	if err != nil {
		fatal("discover: %v", err)
	}
	for _, pdf := range pdfs {
		complete := filepath.Join(outputDir, pdf, "complete", "complete.txt")
		if _, err := os.Stat(complete); err != nil {
			logger.Warn("missing: %s", complete)
			continue
		}
		wavDir := filepath.Join(outputDir, pdf, "wav")
		if err := os.MkdirAll(wavDir, 0o755); err != nil {
			logger.Error("mkdir: %v", err)
			continue
		}
		text := readAll(complete)
		chunks := chunkText(text, 200)
		for i, c := range chunks {
			name := fmt.Sprintf("chunk_%04d.wav", i+1)
			out := filepath.Join(wavDir, name)
			if fi, err := os.Stat(out); err == nil && fi.Size() > 0 {
				continue
			}
			if err := runF5TTS(model, c, out); err != nil {
				logger.Warn("tts fail: %v", err)
			}
		}
		logger.Success("generated %d chunks for %s", len(chunks), pdf)
	}
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

func chunkText(text string, target int) []string {
	var chunks []string
	var current strings.Builder
	s := bufio.NewScanner(strings.NewReader(text))
	s.Split(bufio.ScanLines)
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if line == "" {
			continue
		}
		if current.Len()+len(line)+1 > target {
			if current.Len() > 0 {
				chunks = append(chunks, current.String())
				current.Reset()
			}
			current.WriteString(line)
		} else {
			if current.Len() > 0 {
				current.WriteByte(' ')
			}
			current.WriteString(line)
		}
	}
	if current.Len() > 0 {
		chunks = append(chunks, current.String())
	}
	return chunks
}

func runF5TTS(model, text, out string) error {
	cmd := exec.Command("f5-tts_infer-cli", "-m", model, "-t", text, "-o", filepath.Dir(out), "-w", filepath.Base(out), "--remove_silence", "--load_vocoder_from_local", "--ref_text", "", "--no_legacy_text")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func readAll(path string) string { b, _ := os.ReadFile(path); return string(b) }
func timestamp() string          { return time.Now().Format("20060102_150405") }

func mustGetwd() string {
	wd, err := os.Getwd()
	if err != nil {
		panic(err)
	}
	return wd
}

func fatal(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
