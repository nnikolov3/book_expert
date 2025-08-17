package main

// pdf-to-png: Highly parallel PDF → PNG renderer with blank-page skipping using the existing Go detector
// This replaces scripts/generate_png.sh.

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"book-expert/internal/config"
	"book-expert/internal/logging"
)

type renderJob struct {
	pdfPath    string
	pageIndex  int
	dpi        int
	outputPath string
}

func main() {
	start := time.Now()
	projectRoot, cfgPath, err := config.FindProjectRoot(mustGetwd())
	if err != nil {
		fatal("find project root: %v", err)
	}
	cfg, err := config.Load(cfgPath)
	if err != nil {
		fatal("load config: %v", err)
	}

	logDir := cfg.LogsDir.PDFToPNG
	if logDir == "" {
		logDir = filepath.Join(projectRoot, "logs", "pdf_to_png")
	}
	logger, err := logging.New(logDir, fmt.Sprintf("log_%s.log", time.Now().Format("20060102_150405")))
	if err != nil {
		fatal("init logger: %v", err)
	}
	defer logger.Close()

	inputDir := cfg.Paths.InputDir
	outputDir := cfg.Paths.OutputDir
	if inputDir == "" || outputDir == "" {
		fatal("paths.input_dir or paths.output_dir missing in project.toml")
	}

	dpi := cfg.Settings.DPI
	if dpi <= 0 {
		dpi = 200
	}

	workers := cfg.Settings.Workers
	if workers <= 0 {
		workers = runtime.NumCPU()
	}

	skipBlanks := cfg.Settings.SkipBlankPages
	fuzz := cfg.BlankDetection.FastFuzzPercent
	if fuzz <= 0 {
		fuzz = 5
	}
	threshold := cfg.BlankDetection.FastNonWhiteThreshold
	if threshold <= 0 {
		threshold = 0.005
	}

	logger.Info("PDF->PNG start: input=%s output=%s dpi=%d workers=%d skipBlanks=%v fuzz=%d thr=%.4f", inputDir, outputDir, dpi, workers, skipBlanks, fuzz, threshold)

	pdfs, err := discoverPDFs(inputDir)
	if err != nil {
		fatal("discover pdfs: %v", err)
	}
	if len(pdfs) == 0 {
		logger.Error("No PDFs found in %s", inputDir)
		os.Exit(1)
	}

	for _, pdf := range pdfs {
		if err := processOnePDF(logger, pdf, outputDir, dpi, workers, skipBlanks, fuzz, threshold); err != nil {
			logger.Error("Failed: %s: %v", filepath.Base(pdf), err)
		} else {
			logger.Success("Completed %s", filepath.Base(pdf))
		}
	}

	logger.Success("All done in %s", time.Since(start))
}

func processOnePDF(logger *logging.Logger, pdfPath string, baseOutput string, dpi int, workers int, skipBlanks bool, fuzz int, thr float64) error {
	pdfName := strings.TrimSuffix(filepath.Base(pdfPath), ".pdf")
	outDir := filepath.Join(baseOutput, pdfName, "png")
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return fmt.Errorf("mkdir: %w", err)
	}
	pages, err := getPDFPages(pdfPath)
	if err != nil {
		return fmt.Errorf("pdfinfo: %w", err)
	}
	if pages <= 0 {
		return errors.New("invalid page count")
	}
	logger.Info("Rendering %d pages -> %s", pages, outDir)

	jobs := make(chan renderJob, workers*2)
	var wg sync.WaitGroup
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for job := range jobs {
				if err := renderPage(ctx, job.pdfPath, job.pageIndex, job.dpi, job.outputPath); err != nil {
					logger.Warn("ghostscript page %d failed: %v", job.pageIndex, err)
					continue
				}
				if skipBlanks {
					isBlank, err := isBlankFast(job.outputPath, fuzz, thr)
					if err != nil {
						logger.Warn("blank detect failed for %s: %v", filepath.Base(job.outputPath), err)
					} else if isBlank {
						_ = os.Remove(job.outputPath)
						logger.Info("Removed blank: %s", filepath.Base(job.outputPath))
					}
				}
			}
		}()
	}

	for p := 1; p <= pages; p++ {
		png := filepath.Join(outDir, fmt.Sprintf("page_%04d.png", p))
		jobs <- renderJob{pdfPath: pdfPath, pageIndex: p, dpi: dpi, outputPath: png}
	}
	close(jobs)
	wg.Wait()

	count, _ := countFiles(outDir, ".png")
	logger.Info("Generated %d PNG files", count)
	return nil
}

func discoverPDFs(dir string) ([]string, error) {
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
			out = append(out, filepath.Join(dir, name))
		}
	}
	return out, nil
}

func getPDFPages(pdfPath string) (int, error) {
	cmd := exec.Command("pdfinfo", pdfPath)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return 0, err
	}
	if err := cmd.Start(); err != nil {
		return 0, err
	}
	scanner := bufio.NewScanner(stdout)
	pages := 0
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "Pages:") {
			parts := strings.Fields(line)
			if len(parts) >= 2 {
				v, _ := strconv.Atoi(parts[1])
				pages = v
			}
		}
	}
	if err := cmd.Wait(); err != nil {
		return 0, err
	}
	if pages <= 0 {
		return 0, errors.New("pages not found")
	}
	return pages, nil
}

func renderPage(ctx context.Context, pdfPath string, page int, dpi int, out string) error {
	args := []string{
		"-q", "-dNOPAUSE", "-dBATCH",
		"-sDEVICE=png16m",
		fmt.Sprintf("-r%d", dpi),
		fmt.Sprintf("-dFirstPage=%d", page),
		fmt.Sprintf("-dLastPage=%d", page),
		"-o", out,
		"-dTextAlphaBits=4",
		"-dGraphicsAlphaBits=4",
		"-dDownScaleFactor=1",
		"-dPDFFitPage",
		pdfPath,
	}
	cmd := exec.CommandContext(ctx, "ghostscript", args...)
	cmd.Stderr = os.Stderr
	cmd.Stdout = os.Stdout
	return cmd.Run()
}

func isBlankFast(pngPath string, fuzzPercent int, threshold float64) (bool, error) {
	// Reuse the existing Go detector binary in bin/detect-blank if present; else fallback to running source with `go run`.
	binary := filepath.Join("bin", "detect-blank")
	args := []string{pngPath, strconv.Itoa(fuzzPercent), fmt.Sprintf("%.6f", threshold)}

	// Interpret detector exit codes consistently:
	// 0 => blank (true, nil), 1 => not blank (false, nil), other => error
	interpret := func(runErr error) (bool, error) {
		if runErr == nil {
			return true, nil
		}
		var exitErr *exec.ExitError
		if errors.As(runErr, &exitErr) {
			switch exitErr.ExitCode() {
			case 0:
				return true, nil
			case 1:
				return false, nil
			default:
				return false, fmt.Errorf("blank detector exit code %d", exitErr.ExitCode())
			}
		}
		return false, runErr
	}

	if _, err := os.Stat(binary); err == nil {
		cmd := exec.Command(binary, args...)
		return interpret(cmd.Run())
	}

	cmd := exec.Command("go", append([]string{"run", "./scripts/Go/detect_blank_go.go"}, args...)...)
	return interpret(cmd.Run())
}

func countFiles(dir string, ext string) (int, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0, err
	}
	c := 0
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if strings.HasSuffix(strings.ToLower(e.Name()), strings.ToLower(ext)) {
			c++
		}
	}
	return c, nil
}

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
