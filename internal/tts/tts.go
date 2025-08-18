// Package tts provides native Go text-to-speech functionality.
//
// This package implements TTS models natively in Go, ported from Coqui TTS.
// No Python dependencies - pure Go implementation using Gorgonia for neural networks.
//
// Architecture:
// - Text Processing: Phoneme conversion, text normalization
// - Neural Networks: Tacotron2, VITS, etc. implemented in Gorgonia
// - Audio Processing: Spectrogram generation, Griffin-Lim vocoding
// - Model Loading: PyTorch .pth and ONNX model weight loading
//
// Key features:
// - Native Go implementation (no Python subprocess)
// - GPU acceleration via Gorgonia CUDA support
// - Configurable memory management for GPU constraints
// - Parallel processing optimized for chunked text
//
// Usage example:
//
//	cfg, _ := config.Load("project.toml")
//	engine := tts.NewEngine(cfg.F5TTSSettings, cfg.Paths)
//	err := engine.ProcessChunks("data/pdf/chunks.json", "output/wav")
package tts

import (
	"book-expert/internal/config"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Engine provides the main TTS processing interface using native Go implementation
type Engine struct {
	ttsConfig   config.Config
	textProc    *TextProcessor
	audioProc   *AudioProcessor
	modelEngine *ModelEngine
	workQueue   chan TTSJob
	wg          sync.WaitGroup
}

// TTSJob represents a single text-to-speech conversion task
type TTSJob struct {
	ID         int
	Text       string
	OutputPath string
}

// TTSResult represents the result of a TTS conversion
type TTSResult struct {
	JobID     int
	Success   bool
	Error     error
	Duration  time.Duration
	AudioPath string
}

// NewEngine creates a new native Go TTS engine
func NewEngine(cfg config.Config) (*Engine, error) {
	// Validate configuration
	if cfg.TTSSettings.Model == "" {
		return nil, fmt.Errorf("tts model name cannot be empty")
	}
	if cfg.TTSSettings.Workers <= 0 {
		cfg.TTSSettings.Workers = 2 // Default fallback
	}
	if cfg.TTSSettings.TimeoutSeconds <= 0 {
		cfg.TTSSettings.TimeoutSeconds = 300 // 5 minute default
	}
	if cfg.TTSSettings.GPUMemoryLimitGB <= 0 {
		cfg.TTSSettings.GPUMemoryLimitGB = 5.5 // Default fallback
	}

	// Initialize text processor
	textProc, err := NewTextProcessor()
	if err != nil {
		return nil, fmt.Errorf("failed to initialize text processor: %w", err)
	}

	// Initialize audio processor
	audioProc, err := NewAudioProcessor()
	if err != nil {
		return nil, fmt.Errorf("failed to initialize audio processor: %w", err)
	}

	// Initialize model engine
	modelEngine, err := NewModelEngine(cfg)
	if err != nil {
		return nil, fmt.Errorf("failed to initialize model engine: %w", err)
	}

	engine := &Engine{
		ttsConfig:   cfg,
		textProc:    textProc,
		audioProc:   audioProc,
		modelEngine: modelEngine,
		workQueue:   make(chan TTSJob, cfg.TTSSettings.Workers*2),
	}

	return engine, nil
}

// ProcessChunks reads a JSON chunk file and converts all chunks to audio files
func (e *Engine) ProcessChunks(chunksPath, outputDir string) error {
	// Load chunks from JSON file
	chunks, err := loadChunks(chunksPath)
	if err != nil {
		return fmt.Errorf("failed to load chunks: %w", err)
	}

	if len(chunks) == 0 {
		return fmt.Errorf("no chunks found in %s", chunksPath)
	}

	// Create output directory
	if err := os.MkdirAll(outputDir, 0755); err != nil {
		return fmt.Errorf("failed to create output directory %s: %w", outputDir, err)
	}

	// Start worker pool
	resultsChan := make(chan TTSResult, len(chunks))
	for i := 0; i < e.ttsConfig.TTSSettings.Workers; i++ {
		go e.worker(resultsChan)
	}

	// Queue all jobs
	for i, chunk := range chunks {
		outputPath := filepath.Join(outputDir, fmt.Sprintf("chunk_%04d.wav", i+1))
		job := TTSJob{
			ID:         i + 1,
			Text:       chunk,
			OutputPath: outputPath,
		}

		e.wg.Add(1)
		e.workQueue <- job
	}

	// Close queue and wait for completion
	close(e.workQueue)
	e.wg.Wait()
	close(resultsChan)

	// Collect results
	var errors []string
	successCount := 0

	for result := range resultsChan {
		if result.Success {
			successCount++
		} else {
			errors = append(errors, fmt.Sprintf("chunk %d failed: %v", result.JobID, result.Error))
		}
	}

	// Report results
	if len(errors) > 0 {
		return fmt.Errorf("TTS processing failed for %d/%d chunks:\n%s",
			len(errors), len(chunks), strings.Join(errors, "\n"))
	}

	return nil
}

// worker processes TTS jobs from the work queue using native Go implementation
func (e *Engine) worker(results chan<- TTSResult) {
	for job := range e.workQueue {
		result := e.processJob(job)
		results <- result
		e.wg.Done()
	}
}

// processJob converts a single text chunk to audio using native Go TTS
func (e *Engine) processJob(job TTSJob) TTSResult {
	startTime := time.Now()

	// Step 1: Text preprocessing and phoneme conversion
	phonemes, err := e.textProc.TextToPhonemes(job.Text)
	if err != nil {
		return TTSResult{
			JobID:    job.ID,
			Success:  false,
			Error:    fmt.Errorf("text processing failed: %w", err),
			Duration: time.Since(startTime),
		}
	}

	// Step 2: Neural network inference to generate mel-spectrogram
	melSpec, err := e.modelEngine.PhonemesToMelSpectrogram(phonemes)
	if err != nil {
		return TTSResult{
			JobID:    job.ID,
			Success:  false,
			Error:    fmt.Errorf("model inference failed: %w", err),
			Duration: time.Since(startTime),
		}
	}

	// Step 3: Convert mel-spectrogram to audio waveform
	waveform, err := e.audioProc.MelSpectrogramToWaveform(melSpec)
	if err != nil {
		return TTSResult{
			JobID:    job.ID,
			Success:  false,
			Error:    fmt.Errorf("audio processing failed: %w", err),
			Duration: time.Since(startTime),
		}
	}

	// Step 4: Save audio to WAV file
	err = e.audioProc.SaveWaveformToFile(waveform, job.OutputPath)
	if err != nil {
		return TTSResult{
			JobID:    job.ID,
			Success:  false,
			Error:    fmt.Errorf("audio save failed: %w", err),
			Duration: time.Since(startTime),
		}
	}

	return TTSResult{
		JobID:     job.ID,
		Success:   true,
		Error:     nil,
		Duration:  time.Since(startTime),
		AudioPath: job.OutputPath,
	}
}

// ProcessSingleChunk converts a single text chunk to audio (useful for testing)
func (e *Engine) ProcessSingleChunk(text, outputPath string) error {
	job := TTSJob{
		ID:         1,
		Text:       text,
		OutputPath: outputPath,
	}

	result := e.processJob(job)
	if !result.Success {
		return result.Error
	}

	return nil
}

// GetSupportedModels returns a list of available TTS models that can be loaded
func (e *Engine) GetSupportedModels() []string {
	return e.modelEngine.GetSupportedModels()
}

// loadChunks reads and parses a JSON chunk file
func loadChunks(path string) ([]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("failed to open chunks file %s: %w", path, err)
	}
	defer file.Close()

	data, err := io.ReadAll(file)
	if err != nil {
		return nil, fmt.Errorf("failed to read chunks file: %w", err)
	}

	var chunks []string
	if err := json.Unmarshal(data, &chunks); err != nil {
		return nil, fmt.Errorf("failed to parse chunks JSON: %w", err)
	}

	return chunks, nil
}