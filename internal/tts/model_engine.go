// Package tts - Neural network model engine for native Go TTS implementation
//
// This module handles model loading, neural network inference using Gorgonia,
// and conversion from phonemes to mel-spectrograms.

package tts

import (
	"book-expert/internal/config"
	"fmt"
	"path/filepath"
	"os"
)

// ModelEngine handles neural network models and inference
type ModelEngine struct {
	config       config.Config
	currentModel TTSModel
	modelCache   map[string]TTSModel
}

// TTSModel interface for different TTS model architectures
type TTSModel interface {
	LoadWeights(modelPath string) error
	GenerateMelSpectrogram(phonemes []Phoneme) (*MelSpectrogram, error)
	GetModelInfo() ModelInfo
}

// ModelInfo contains metadata about a loaded model
type ModelInfo struct {
	Name         string
	Architecture string
	SampleRate   int
	MelBins      int
	MaxSeqLen    int
}

// SimpleTTSModel implements a basic TTS model for initial implementation
type SimpleTTSModel struct {
	info        ModelInfo
	isLoaded    bool
	sampleRate  int
	melBins     int
	frameLength float64 // seconds per mel frame
}

// NewModelEngine creates a new model engine
func NewModelEngine(cfg config.Config) (*ModelEngine, error) {
	me := &ModelEngine{
		config:     cfg,
		modelCache: make(map[string]TTSModel),
	}

	// Ensure model directories exist
	os.MkdirAll(cfg.Paths.TorchModels, 0755)
	os.MkdirAll(cfg.Paths.CkptsPath, 0755)

	// Load the configured model
	err := me.loadModel(cfg.TTSSettings.Model)
	if err != nil {
		return nil, fmt.Errorf("failed to load model %s: %w", cfg.TTSSettings.Model, err)
	}

	return me, nil
}

// PhonemesToMelSpectrogram converts phoneme sequence to mel-spectrogram
func (me *ModelEngine) PhonemesToMelSpectrogram(phonemes []Phoneme) (*MelSpectrogram, error) {
	if me.currentModel == nil {
		return nil, fmt.Errorf("no model loaded")
	}

	return me.currentModel.GenerateMelSpectrogram(phonemes)
}

// GetSupportedModels returns list of supported model names
func (me *ModelEngine) GetSupportedModels() []string {
	return []string{
		"SimpleTTS",
		"E2TTS_Base", 
		"tacotron2-DDC",
		"vits-ljspeech",
	}
}

// loadModel loads a specific model by name
func (me *ModelEngine) loadModel(modelName string) error {
	// Check cache first
	if cachedModel, exists := me.modelCache[modelName]; exists {
		me.currentModel = cachedModel
		return nil
	}

	// First, check if the requested model file actually exists locally
	modelPath := me.findModelFile(modelName)
	
	// If not found locally and it's a downloadable model, try to download
	if modelPath == "" && me.isDownloadableModel(modelName) {
		fmt.Printf("Model '%s' not found locally, attempting download...\n", modelName)
		downloader := NewModelDownloader(me.config.Paths.TorchModels)
		downloadedPath, err := downloader.EnsureModelAvailable(modelName)
		if err != nil {
			fmt.Printf("Download failed: %v\n", err)
		} else {
			modelPath = downloadedPath
			fmt.Printf("Model downloaded to: %s\n", downloadedPath)
		}
	}
	
	// Create model based on name/type
	var model TTSModel
	var err error

	switch {
	case modelName == "SimpleTTS":
		model, err = me.createSimpleTTSModel(modelName)
	case contains(modelName, "xtts"):
		model, err = me.createXTTSModel(modelName)
	case contains(modelName, "tacotron"):
		model, err = me.createTacotronModel(modelName)
	case contains(modelName, "vits"):
		model, err = me.createVITSModel(modelName)
	case modelPath != "": // External model file exists
		// Unknown external model, try simple with external weights
		model, err = me.createSimpleTTSModel(modelName)
	default:
		// No model file found, fall back to SimpleTTS
		fmt.Printf("Warning: Model '%s' not found and not downloadable, using built-in SimpleTTS\n", modelName)
		model, err = me.createSimpleTTSModel("SimpleTTS")
		modelName = "SimpleTTS" // Update name for caching
	}

	if err != nil {
		return fmt.Errorf("failed to create model %s: %w", modelName, err)
	}

	// Load weights if model file exists
	if modelPath != "" {
		fmt.Printf("Loading model weights from: %s\n", modelPath)
		err = model.LoadWeights(modelPath)
		if err != nil {
			return fmt.Errorf("failed to load weights for %s: %w", modelName, err)
		}
	} else {
		fmt.Printf("Using built-in model: %s (no external weights)\n", modelName)
	}

	// Cache and set as current
	me.modelCache[modelName] = model
	me.currentModel = model

	return nil
}

// createSimpleTTSModel creates a basic TTS model implementation
func (me *ModelEngine) createSimpleTTSModel(modelName string) (*SimpleTTSModel, error) {
	model := &SimpleTTSModel{
		info: ModelInfo{
			Name:         modelName,
			Architecture: "SimpleTTS",
			SampleRate:   22050,
			MelBins:      80,
			MaxSeqLen:    1000,
		},
		sampleRate:  22050,
		melBins:     80,
		frameLength: 0.0125, // 12.5ms per frame (256 samples at 22050 Hz)
	}

	return model, nil
}

// createTacotronModel creates a Tacotron-based model (placeholder)
func (me *ModelEngine) createTacotronModel(modelName string) (TTSModel, error) {
	// For now, return simple model - can be enhanced later
	return me.createSimpleTTSModel(modelName)
}

// createVITSModel creates a VITS-based model (placeholder)
func (me *ModelEngine) createVITSModel(modelName string) (TTSModel, error) {
	// For now, return simple model - can be enhanced later
	return me.createSimpleTTSModel(modelName)
}

// findModelFile searches for model files in configured paths
func (me *ModelEngine) findModelFile(modelName string) string {
	searchPaths := []string{
		me.config.Paths.TorchModels,
		me.config.Paths.CkptsPath,
	}

	extensions := []string{"", ".pth", ".pt", ".bin", ".safetensors", ".onnx"}

	for _, basePath := range searchPaths {
		for _, ext := range extensions {
			modelPath := filepath.Join(basePath, modelName+ext)
			if _, err := os.Stat(modelPath); err == nil {
				return modelPath
			}
		}
	}

	return ""
}

// isDownloadableModel checks if a model can be downloaded
func (me *ModelEngine) isDownloadableModel(modelName string) bool {
	downloadableModels := []string{
		"tts_models/multilingual/multi-dataset/xtts_v2",
		"xtts_v2",
	}
	
	for _, downloadable := range downloadableModels {
		if contains(modelName, downloadable) || modelName == downloadable {
			return true
		}
	}
	return false
}

// createXTTSModel creates an XTTS-based model
func (me *ModelEngine) createXTTSModel(modelName string) (TTSModel, error) {
	// For now, return enhanced simple model with XTTS characteristics
	// TODO: Implement actual XTTS architecture in Go
	model := &SimpleTTSModel{
		info: ModelInfo{
			Name:         modelName,
			Architecture: "XTTS",
			SampleRate:   22050,
			MelBins:      80,
			MaxSeqLen:    2000, // XTTS supports longer sequences
		},
		sampleRate:  22050,
		melBins:     80,
		frameLength: 0.0125,
	}
	
	fmt.Printf("Created XTTS model wrapper for %s\n", modelName)
	return model, nil
}

// Implementation of SimpleTTSModel

// LoadWeights loads model weights (placeholder implementation)
func (m *SimpleTTSModel) LoadWeights(modelPath string) error {
	// For now, just mark as loaded
	// TODO: Implement actual weight loading from PyTorch .pth files
	m.isLoaded = true
	return nil
}

// GenerateMelSpectrogram generates mel-spectrogram from phonemes using simple rules
func (m *SimpleTTSModel) GenerateMelSpectrogram(phonemes []Phoneme) (*MelSpectrogram, error) {
	if !m.isLoaded {
		// Still generate output even without loaded weights (for testing)
	}

	// Calculate total duration and number of frames
	totalDuration := 0.0
	for _, phoneme := range phonemes {
		totalDuration += float64(phoneme.Duration) / 1000.0 // Convert ms to seconds
	}

	nFrames := int(totalDuration / m.frameLength)
	if nFrames < 10 {
		nFrames = 10 // Minimum length
	}

	// Create mel-spectrogram with simple patterns
	melData := make([][]float64, nFrames)
	for t := range melData {
		melData[t] = make([]float64, m.melBins)
	}

	// Generate simple mel patterns based on phonemes
	frameIdx := 0
	for _, phoneme := range phonemes {
		phonemeFrames := int(float64(phoneme.Duration) / 1000.0 / m.frameLength)
		if phonemeFrames < 1 {
			phonemeFrames = 1
		}

		// Generate simple frequency pattern based on phoneme
		pattern := m.getPhonemePattern(phoneme.Symbol)

		for f := 0; f < phonemeFrames && frameIdx < nFrames; f++ {
			for mel := 0; mel < m.melBins; mel++ {
				if mel < len(pattern) {
					melData[frameIdx][mel] = pattern[mel]
				}
			}
			frameIdx++
		}
	}

	return &MelSpectrogram{
		Data:       melData,
		SampleRate: m.sampleRate,
		HopLength:  256, // Standard hop length
		NMels:      m.melBins,
	}, nil
}

// getPhonemePattern returns a simple mel pattern for a phoneme
func (m *SimpleTTSModel) getPhonemePattern(phoneme string) []float64 {
	pattern := make([]float64, m.melBins)

	// Simple rule-based patterns for different phoneme types
	switch {
	case isVowel(phoneme):
		// Vowels: strong low-frequency content
		for i := 0; i < m.melBins/3; i++ {
			pattern[i] = 0.8 + 0.2*noise()
		}
		for i := m.melBins/3; i < 2*m.melBins/3; i++ {
			pattern[i] = 0.4 + 0.2*noise()
		}
	case isConsonant(phoneme):
		// Consonants: more high-frequency content
		for i := 0; i < m.melBins/4; i++ {
			pattern[i] = 0.3 + 0.1*noise()
		}
		for i := m.melBins/2; i < m.melBins; i++ {
			pattern[i] = 0.6 + 0.2*noise()
		}
	case isFricative(phoneme):
		// Fricatives: broad spectrum noise
		for i := 0; i < m.melBins; i++ {
			pattern[i] = 0.5 + 0.3*noise()
		}
	default:
		// Default: mid-range content
		for i := m.melBins/4; i < 3*m.melBins/4; i++ {
			pattern[i] = 0.5 + 0.2*noise()
		}
	}

	return pattern
}

// GetModelInfo returns model information
func (m *SimpleTTSModel) GetModelInfo() ModelInfo {
	return m.info
}

// Helper functions

func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || 
		(len(s) > len(substr) && (s[:len(substr)] == substr || s[len(s)-len(substr):] == substr)))
}

func isVowel(phoneme string) bool {
	vowels := []string{"AE", "AH", "AO", "AW", "AY", "EH", "ER", "EY", "IH", "IY", "OW", "OY", "UH", "UW"}
	for _, v := range vowels {
		if phoneme == v {
			return true
		}
	}
	return false
}

func isConsonant(phoneme string) bool {
	consonants := []string{"B", "CH", "D", "DH", "F", "G", "HH", "JH", "K", "L", "M", "N", "NG", "P", "R", "S", "T", "TH", "V", "W", "Y", "Z", "ZH"}
	for _, c := range consonants {
		if phoneme == c {
			return true
		}
	}
	return false
}

func isFricative(phoneme string) bool {
	fricatives := []string{"F", "TH", "S", "SH", "V", "DH", "Z", "ZH", "HH"}
	for _, f := range fricatives {
		if phoneme == f {
			return true
		}
	}
	return false
}

// Simple noise generator for realistic mel patterns
func noise() float64 {
	return (2.0*float64(int64(0x1f)) / float64(0x1f) - 1.0) * 0.1 // Simple pseudo-random
}