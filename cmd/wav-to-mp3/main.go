package main

// wav-to-mp3: Resample and merge WAV chunks, then convert to MP3, replacing scripts/generate_mp3.sh

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
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

	logDir := cfg.LogsDir.CombineChunks
	if logDir == "" {
		logDir = filepath.Join(root, "logs", "combine_chunks")
	}
	logger, err := logging.New(logDir, "log.txt")
	if err != nil {
		fatal("logger: %v", err)
	}
	defer logger.Close()

	inputDir := cfg.Paths.InputDir
	outputDir := cfg.Paths.OutputDir
	if inputDir == "" || outputDir == "" {
		fatal("missing config paths")
	}

	pdfs, err := listPDFBaseNames(inputDir)
	if err != nil {
		fatal("discover pdfs: %v", err)
	}
	for _, pdf := range pdfs {
		wavDir := filepath.Join(outputDir, pdf, "wav")
		resampleDir := filepath.Join(outputDir, pdf, "resampled")
		mp3Dir := filepath.Join(outputDir, pdf, "mp3")
		finalWav := filepath.Join(resampleDir, pdf+"_final.wav")
		finalMp3 := filepath.Join(mp3Dir, pdf+".mp3")

		if err := os.MkdirAll(resampleDir, 0o755); err != nil {
			logger.Error("mkdir: %v", err)
			continue
		}
		if err := os.MkdirAll(mp3Dir, 0o755); err != nil {
			logger.Error("mkdir: %v", err)
			continue
		}

		wavs, err := listWavsSorted(wavDir)
		if err != nil || len(wavs) == 0 {
			logger.Warn("no wavs for %s", pdf)
			continue
		}

		listFile := filepath.Join(resampleDir, "concat_list.txt")
		if err := resampleAll(wavs, resampleDir, listFile, logger); err != nil {
			logger.Error("resample: %v", err)
			continue
		}
		if err := ffmpegConcat(listFile, finalWav); err != nil {
			logger.Error("concat: %v", err)
			continue
		}
		if err := convertToMp3(finalWav, finalMp3); err != nil {
			logger.Error("mp3: %v", err)
			continue
		}
		logger.Success("mp3 created: %s", finalMp3)
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

func listWavsSorted(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var out []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if strings.HasSuffix(strings.ToLower(e.Name()), ".wav") {
			out = append(out, filepath.Join(dir, e.Name()))
		}
	}
	sort.Strings(out)
	return out, nil
}

func resampleAll(wavs []string, resampleDir, listFile string, logger *logging.Logger) error {
	f, err := os.Create(listFile)
	if err != nil {
		return err
	}
	defer f.Close()
	writer := bufio.NewWriter(f)
	for _, w := range wavs {
		out := filepath.Join(resampleDir, filepath.Base(w))
		if err := ffmpegResample(w, out); err != nil {
			return err
		}
		fmt.Fprintf(writer, "file %s\n", out)
	}
	return writer.Flush()
}

func ffmpegResample(in, out string) error {
	cmd := exec.Command("ffmpeg", "-i", in, "-ar", "48000", "-ac", "1", "-c:a", "pcm_s32le", "-af", "aresample=async=1:first_pts=0", "-rf64", "auto", "-hide_banner", "-loglevel", "error", "-y", out)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func ffmpegConcat(listFile, out string) error {
	cmd := exec.Command("ffmpeg", "-f", "concat", "-safe", "0", "-i", listFile, "-c", "copy", "-avoid_negative_ts", "make_zero", "-fflags", "+genpts", "-max_muxing_queue_size", "4096", "-rf64", "auto", "-hide_banner", "-loglevel", "error", "-y", out)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func convertToMp3(in, out string) error {
	cmd := exec.Command("ffmpeg", "-i", in, "-c:a", "libmp3lame", "-q:a", "0", "-hide_banner", "-loglevel", "error", "-y", out)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func mustGetwd() string {
	wd, err := os.Getwd()
	if err != nil {
		panic(err)
	}
	return wd
}
func fatal(format string, args ...any) { fmt.Fprintf(os.Stderr, format+"\n", args...); os.Exit(1) }
