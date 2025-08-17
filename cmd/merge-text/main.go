package main

// merge-text: Concatenate text files (final_text or unified_text) into a single complete.txt
// Replaces scripts/merge_text.sh

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

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

	logDir := cfg.LogsDir.NarrationTextConcat
	if logDir == "" {
		logDir = filepath.Join(root, "logs", "final_text")
	}
	logger, err := logging.New(logDir, "narration_text_concat.log")
	if err != nil {
		fatal("logger: %v", err)
	}
	defer logger.Close()

	inputDir := cfg.Paths.InputDir
	outputDir := cfg.Paths.OutputDir
	textType := cfg.TextConcatenation.TextType
	if textType == "" {
		textType = "final_text"
	}

	pdfs, err := listPDFBaseNames(inputDir)
	if err != nil {
		fatal("discover pdfs: %v", err)
	}
	for _, pdf := range pdfs {
		textDir := filepath.Join(outputDir, pdf, textType)
		completeDir := filepath.Join(outputDir, pdf, "complete")
		if err := os.MkdirAll(completeDir, 0o755); err != nil {
			logger.Error("mkdir: %v", err)
			continue
		}
		completePath := filepath.Join(completeDir, "complete.txt")

		files, err := listTextFiles(textDir)
		if err != nil || len(files) == 0 {
			logger.Warn("no %s files for %s", textType, pdf)
			continue
		}
		if err := concat(files, completePath); err != nil {
			logger.Error("concat failed for %s: %v", pdf, err)
			continue
		}
		logger.Success("wrote %s", completePath)
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

func listTextFiles(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var out []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if strings.HasSuffix(strings.ToLower(e.Name()), ".txt") {
			out = append(out, filepath.Join(dir, e.Name()))
		}
	}
	sort.Strings(out)
	return out, nil
}

func concat(files []string, out string) error {
	f, err := os.Create(out)
	if err != nil {
		return err
	}
	defer f.Close()
	for _, p := range files {
		in, err := os.Open(p)
		if err != nil {
			return err
		}
		if _, err := io.Copy(f, in); err != nil {
			in.Close()
			return err
		}
		in.Close()
		if _, err := f.WriteString("\n\n"); err != nil {
			return err
		}
	}
	return nil
}

func mustGetwd() string {
	wd, err := os.Getwd()
	if err != nil {
		panic(err)
	}
	return wd
}
func fatal(format string, args ...any) { fmt.Fprintf(os.Stderr, format+"\n", args...); os.Exit(1) }
