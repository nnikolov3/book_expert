package config

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/pelletier/go-toml/v2"
)

// Config models the subset of project.toml that our Go commands need.
// Extend as required, but keep field names descriptive and aligned with the TOML structure.
type Config struct {
	Project struct {
		Name    string `toml:"name"`
		Version string `toml:"version"`
	} `toml:"project"`

	Paths struct {
		InputDir    string `toml:"input_dir"`
		OutputDir   string `toml:"output_dir"`
		RagInputDir string `toml:"rag_input_dir"`
		PythonPath  string `toml:"python_path"`
		CkptsPath   string `toml:"ckpts_path"`
	} `toml:"paths"`

	Directories struct {
		PolishedDir string `toml:"polished_dir"`
		Chunks      string `toml:"chunks"`
		TTSChunks   string `toml:"tts_chunks"`
		Wav         string `toml:"wav"`
		Mp3         string `toml:"mp3"`
	} `toml:"directories"`

	ProcessingDir struct {
		PDFToPNG            string `toml:"pdf_to_png"`
		PNGToText           string `toml:"png_to_text"`
		UnifyText           string `toml:"unify_text"`
		FinalText           string `toml:"final_text"`
		TextToChunks        string `toml:"text_to_chunks"`
		ChunksToWav         string `toml:"chunks_to_wav"`
		CombineChunks       string `toml:"combine_chunks"`
		NarrationTextConcat string `toml:"narration_text_concat"`
		CleanText           string `toml:"clean_text"`
	} `toml:"processing_dir"`

	LogsDir struct {
		PDFToPNG            string `toml:"pdf_to_png"`
		PNGToText           string `toml:"png_to_text"`
		UnifyText           string `toml:"unify_text"`
		TextToChunks        string `toml:"text_to_chunks"`
		TextToWav           string `toml:"text_to_wav"`
		CombineChunks       string `toml:"combine_chunks"`
		FinalText           string `toml:"final_text"`
		NarrationTextConcat string `toml:"narration_text_concat"`
	} `toml:"logs_dir"`

	Settings struct {
		DPI            int  `toml:"dpi"`
		Workers        int  `toml:"workers"`
		OverlapChars   int  `toml:"overlap_chars"`
		SkipBlankPages bool `toml:"skip_blank_pages"`
		BlankThreshold int  `toml:"blank_threshold"`
		Force          int  `toml:"force"`
	} `toml:"settings"`

	Tesseract struct {
		Language       string `toml:"language"`
		OEM            int    `toml:"oem"`
		PSM            int    `toml:"psm"`
		SkipBlankPages bool   `toml:"skip_blank_pages"`
		BlankThreshold int    `toml:"blank_threshold"`
	} `toml:"tesseract"`

	GoogleAPI struct {
		APIKeyVariable string `toml:"api_key_variable"`
		MaxRetries     int    `toml:"max_retries"`
		RetryDelaySec  int    `toml:"retry_delay_seconds"`
	} `toml:"google_api"`

	CerebrasAPI struct {
		APIKeyVariable string  `toml:"api_key_variable"`
		MaxTokens      int     `toml:"max_tokens"`
		Temperature    float64 `toml:"temperature"`
		TopP           float64 `toml:"top_p"`
	} `toml:"cerebras_api"`

	F5TTSSettings struct {
		Model          string `toml:"model"`
		Workers        int    `toml:"workers"`
		TimeoutSeconds int    `toml:"timeout_duration"`
	} `toml:"f5_tts_settings"`

	TextConcatenation struct {
		TextType string `toml:"text_type"`
	} `toml:"text_concatenation"`

	BlankDetection struct {
		Method                string  `toml:"method"`
		EntropyThreshold      float64 `toml:"entropy_threshold"`
		WhitePercentThreshold int     `toml:"white_percent_threshold"`
		UniqueColorsThreshold int     `toml:"unique_colors_threshold"`
		StdDevThreshold       float64 `toml:"std_dev_threshold"`
		MeanThreshold         float64 `toml:"mean_threshold"`
		FastNonWhiteThreshold float64 `toml:"fast_non_white_threshold"`
		FastFuzzPercent       int     `toml:"fast_fuzz_percent"`
	} `toml:"blank_detection"`

	Prompts struct {
		UnifyText struct {
			Prompt string `toml:"prompt"`
		} `toml:"unify_text"`
		ExtractText struct {
			Prompt string `toml:"prompt"`
		} `toml:"extract_text"`
		ExtractConcepts struct {
			Prompt string `toml:"prompt"`
		} `toml:"extract_concepts"`
	} `toml:"prompts"`
}

// Load reads a TOML file into Config.
func Load(path string) (Config, error) {
	var cfg Config
	data, err := os.ReadFile(path)
	if err != nil {
		return cfg, fmt.Errorf("read config: %w", err)
	}
	if err := toml.Unmarshal(data, &cfg); err != nil {
		return cfg, fmt.Errorf("parse toml: %w", err)
	}
	return cfg, nil
}

// FindProjectRoot searches upward from startDir until it finds project.toml or hits filesystem root.
// Returns the directory containing project.toml and the full path to the file.
func FindProjectRoot(startDir string) (string, string, error) {
	cur := startDir
	for {
		candidate := filepath.Join(cur, "project.toml")
		if _, err := os.Stat(candidate); err == nil {
			return cur, candidate, nil
		}
		next := filepath.Dir(cur)
		if next == cur {
			break
		}
		cur = next
	}
	return "", "", errors.New("project.toml not found")
}
