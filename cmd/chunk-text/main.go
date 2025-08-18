// main.go
// Pipeline command to discover and chunk text files for natural TTS processing.
// Follows DESIGN_PRINCIPLES_GUIDE.md: Simplicity, modularity, explicit configs, no magic numbers.

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"book-expert/internal/chunking" // Assume this is your refactored package; see example below.
	"book-expert/internal/config"
	"book-expert/internal/logging"
)

func main() {
	// Explicit variables at block top.
	var err error

	wd, err := os.Getwd()
	if err != nil {
		fatal("get working directory: %v", err)
	}

	root, cfgPath, err := config.FindProjectRoot(wd)
	if err != nil {
		fatal("find project root: %v", err)
	}

	cfg, err := config.Load(cfgPath)
	if err != nil {
		fatal("load config: %v", err)
	}

	logDir := cfg.LogsDir.TextToChunks
	if logDir == "" {
		logDir = filepath.Join(root, "logs", "text_to_chunks")
	}

	logger, err := logging.New(logDir, "chunk_text.log")
	if err != nil {
		fatal("create logger: %v", err)
	}
	defer logger.Close()

	inputDir := cfg.Paths.InputDir
	outputDir := cfg.Paths.OutputDir

	// Create chunker with explicit config for natural speech chunking.
	chunkConfig := chunking.Config{
		TargetSize: cfg.Chunking.TargetSize, // e.g., 200 chars for optimal TTS.
		MaxSize:    cfg.Chunking.MaxSize,    // e.g., 500 to avoid API limits.
		MinSize:    cfg.Chunking.MinSize,    // e.g., 50 to prevent tiny fragments.
	}
	chunker := chunking.NewChunker(chunkConfig)

	logger.Info("Starting text chunking with config: target=%d, max=%d, min=%d",
		chunkConfig.TargetSize, chunkConfig.MaxSize, chunkConfig.MinSize)

	pdfs, err := listPDFBaseNames(inputDir)
	if err != nil {
		fatal("list PDFs: %v", err)
	}

	for _, pdf := range pdfs {
		completeFile := filepath.Join(outputDir, pdf, "final_complete", "final_text.txt")
		if _, err := os.Stat(completeFile); err != nil {
			logger.Warn("missing final_text.txt for %s: %s", pdf, completeFile)
			continue
		}

		// Chunk with natural speech logic; outputs to chunks.json.
		if err := chunker.ChunkFile(completeFile, outputDir, pdf); err != nil {
			logger.Error("chunk %s: %v", pdf, err)
			continue
		}

		logger.Success("chunked %s -> %s/chunks.json", pdf, filepath.Join(outputDir, pdf))
	}

	logger.Info("Text chunking completed")
}

// listPDFBaseNames returns base names of PDFs in dir.
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
			// Remove extension preserving original case of the base name
			baseName := name[:len(name)-4] // Remove last 4 characters (.pdf/.PDF/.Pdf etc.)
			out = append(out, baseName)
		}
	}
	return out, nil
}

// fatal prints error and exits.
func fatal(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
