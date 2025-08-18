package tts

import (
	"book-expert/internal/config"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// setupTestConfig creates a test configuration for TTS testing
func setupTestConfig(t *testing.T) (config.F5TTSSettings, config.Paths, string) {
	t.Helper()
	
	tempDir := t.TempDir()
	
	ttsConfig := config.F5TTSSettings{
		Model:             "tts_models/en/ljspeech/tacotron2-DDC",
		Workers:           1, // Use single worker for deterministic tests
		TimeoutSeconds:    60,
		GPUMemoryLimitGB:  2.0,
		UseGPU:           false, // Disable GPU for tests
	}
	
	paths := config.Paths{
		PythonPath:   "/usr/bin", // Use system python for tests
		TorchModels:  filepath.Join(tempDir, "torch_models"),
		CkptsPath:    filepath.Join(tempDir, "ckpts"),
	}
	
	// Create test directories
	os.MkdirAll(paths.TorchModels, 0755)
	os.MkdirAll(paths.CkptsPath, 0755)
	
	return ttsConfig, paths, tempDir
}

// createTestChunksFile creates a test JSON chunk file
func createTestChunksFile(t *testing.T, dir string, chunks []string) string {
	t.Helper()
	
	chunksPath := filepath.Join(dir, "chunks.json")
	data, err := json.MarshalIndent(chunks, "", "  ")
	if err != nil {
		t.Fatalf("Failed to marshal test chunks: %v", err)
	}
	
	err = os.WriteFile(chunksPath, data, 0644)
	if err != nil {
		t.Fatalf("Failed to write test chunks file: %v", err)
	}
	
	return chunksPath
}

// Test NewEngine functionality
func TestNewEngine(t *testing.T) {
	tests := []struct {
		name        string
		ttsConfig   config.F5TTSSettings  
		paths       config.Paths
		expectError bool
		errorMsg    string
	}{
		{
			name: "valid_configuration",
			ttsConfig: config.F5TTSSettings{
				Model:             "test-model",
				Workers:           2,
				TimeoutSeconds:    300,
				GPUMemoryLimitGB:  5.5,
				UseGPU:           true,
			},
			paths: config.Paths{
				PythonPath:  "/usr/bin",
				TorchModels: "/tmp/torch_models", 
				CkptsPath:   "/tmp/ckpts",
			},
			expectError: true, // Will fail Python TTS validation
			errorMsg:    "python TTS validation failed",
		},
		{
			name: "empty_model_name",
			ttsConfig: config.F5TTSSettings{
				Model:             "", // Empty model name
				Workers:           2,
				TimeoutSeconds:    300,
				GPUMemoryLimitGB:  5.5,
				UseGPU:           true,
			},
			paths: config.Paths{
				PythonPath:  "/usr/bin",
				TorchModels: "/tmp/torch_models",
				CkptsPath:   "/tmp/ckpts", 
			},
			expectError: true,
			errorMsg:    "tts model name cannot be empty",
		},
		{
			name: "empty_python_path",
			ttsConfig: config.F5TTSSettings{
				Model:             "test-model",
				Workers:           2,
				TimeoutSeconds:    300,
				GPUMemoryLimitGB:  5.5,
				UseGPU:           true,
			},
			paths: config.Paths{
				PythonPath:  "", // Empty python path
				TorchModels: "/tmp/torch_models",
				CkptsPath:   "/tmp/ckpts",
			},
			expectError: true,
			errorMsg:    "python path cannot be empty",
		},
		{
			name: "default_fallbacks",
			ttsConfig: config.F5TTSSettings{
				Model:             "test-model",
				Workers:           0, // Should fallback to 2
				TimeoutSeconds:    0, // Should fallback to 300
				GPUMemoryLimitGB:  0, // Should fallback to 5.5
				UseGPU:           true,
			},
			paths: config.Paths{
				PythonPath:  "/usr/bin",
				TorchModels: "/tmp/torch_models",
				CkptsPath:   "/tmp/ckpts",
			},
			expectError: true, // Will fail Python TTS validation
			errorMsg:    "python TTS validation failed",
		},
	}
	
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			engine, err := NewEngine(tt.ttsConfig, tt.paths)
			
			if tt.expectError {
				if err == nil {
					t.Error("Expected error but got none")
				} else if !strings.Contains(err.Error(), tt.errorMsg) {
					t.Errorf("Expected error containing '%s', got: %v", tt.errorMsg, err)
				}
			} else {
				if err != nil {
					t.Errorf("Unexpected error: %v", err)
				}
				if engine == nil {
					t.Error("Expected non-nil engine")
				}
			}
		})
	}
}

// Test loadChunks functionality
func TestLoadChunks(t *testing.T) {
	tempDir := t.TempDir()
	
	tests := []struct {
		name        string
		chunks      []string
		expectError bool
		errorMsg    string
	}{
		{
			name:   "valid_chunks",
			chunks: []string{"Hello world", "This is a test", "Final chunk"},
			expectError: false,
		},
		{
			name:   "empty_chunks",
			chunks: []string{},
			expectError: false,
		},
		{
			name:   "single_chunk",
			chunks: []string{"Only one chunk"},
			expectError: false,
		},
	}
	
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			chunksPath := createTestChunksFile(t, tempDir, tt.chunks)
			
			loadedChunks, err := loadChunks(chunksPath)
			
			if tt.expectError {
				if err == nil {
					t.Error("Expected error but got none")
				} else if !strings.Contains(err.Error(), tt.errorMsg) {
					t.Errorf("Expected error containing '%s', got: %v", tt.errorMsg, err)
				}
			} else {
				if err != nil {
					t.Errorf("Unexpected error: %v", err)
				}
				if len(loadedChunks) != len(tt.chunks) {
					t.Errorf("Expected %d chunks, got %d", len(tt.chunks), len(loadedChunks))
				}
				for i, chunk := range tt.chunks {
					if i < len(loadedChunks) && loadedChunks[i] != chunk {
						t.Errorf("Chunk %d mismatch: expected '%s', got '%s'", i, chunk, loadedChunks[i])
					}
				}
			}
		})
	}
	
	// Test invalid file
	t.Run("nonexistent_file", func(t *testing.T) {
		_, err := loadChunks("/nonexistent/path/chunks.json")
		if err == nil {
			t.Error("Expected error for nonexistent file")
		}
		if !strings.Contains(err.Error(), "failed to open chunks file") {
			t.Errorf("Unexpected error message: %v", err)
		}
	})
	
	// Test invalid JSON
	t.Run("invalid_json", func(t *testing.T) {
		invalidPath := filepath.Join(tempDir, "invalid.json")
		err := os.WriteFile(invalidPath, []byte("{invalid json}"), 0644)
		if err != nil {
			t.Fatalf("Failed to create invalid JSON file: %v", err)
		}
		
		_, err = loadChunks(invalidPath)
		if err == nil {
			t.Error("Expected error for invalid JSON")
		}
		if !strings.Contains(err.Error(), "failed to parse chunks JSON") {
			t.Errorf("Unexpected error message: %v", err)
		}
	})
}

// Test calculateGPUMemoryFraction functionality  
func TestCalculateGPUMemoryFraction(t *testing.T) {
	tests := []struct {
		name     string
		limitGB  float64
		expected float64
	}{
		{
			name:     "normal_limit",
			limitGB:  5.5,
			expected: 0.6875, // 5.5/8 = 0.6875
		},
		{
			name:     "zero_limit",
			limitGB:  0,
			expected: 0.8, // Default fallback
		},
		{
			name:     "negative_limit", 
			limitGB:  -1.0,
			expected: 0.8, // Default fallback
		},
		{
			name:     "exceed_typical_gpu",
			limitGB:  12.0,
			expected: 0.9, // Safety cap at 90%
		},
		{
			name:     "very_small_limit",
			limitGB:  0.5,
			expected: 0.1, // Minimum 10%
		},
		{
			name:     "very_large_fraction",
			limitGB:  7.8,
			expected: 0.9, // Capped at 90%
		},
	}
	
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := calculateGPUMemoryFraction(tt.limitGB)
			if result != tt.expected {
				t.Errorf("Expected %.4f, got %.4f", tt.expected, result)
			}
		})
	}
}

// Test createTempTextFile functionality
func TestCreateTempTextFile(t *testing.T) {
	tests := []struct {
		name        string
		text        string
		expectError bool
	}{
		{
			name: "normal_text",
			text: "This is a test text for TTS processing.",
			expectError: false,
		},
		{
			name: "empty_text", 
			text: "",
			expectError: false,
		},
		{
			name: "multiline_text",
			text: "Line 1\nLine 2\nLine 3",
			expectError: false,
		},
		{
			name: "unicode_text",
			text: "Hello 世界 🌍 café naïve résumé",
			expectError: false,
		},
	}
	
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tempFile, err := createTempTextFile(tt.text)
			
			if tt.expectError {
				if err == nil {
					t.Error("Expected error but got none")
				}
			} else {
				if err != nil {
					t.Errorf("Unexpected error: %v", err)
				}
				
				// Verify file exists and contains correct content
				if _, err := os.Stat(tempFile); os.IsNotExist(err) {
					t.Error("Temp file was not created")
				}
				
				content, err := os.ReadFile(tempFile)
				if err != nil {
					t.Errorf("Failed to read temp file: %v", err)
				}
				
				if string(content) != tt.text {
					t.Errorf("Content mismatch: expected '%s', got '%s'", tt.text, string(content))
				}
				
				// Clean up
				os.Remove(tempFile)
			}
		})
	}
}

// Test getModelPath functionality
func TestGetModelPath(t *testing.T) {
	ttsConfig, paths, tempDir := setupTestConfig(t)
	
	engine := &Engine{
		ttsConfig: ttsConfig,
		paths:     paths,
	}
	
	tests := []struct {
		name        string
		setupFunc   func()
		expectPath  bool
		expectedDir string
	}{
		{
			name: "no_local_model",
			setupFunc: func() {
				// No setup needed - no local models exist
			},
			expectPath: false,
		},
		{
			name: "torch_models_directory",
			setupFunc: func() {
				modelDir := filepath.Join(paths.TorchModels, ttsConfig.Model)
				os.MkdirAll(modelDir, 0755)
			},
			expectPath:  true,
			expectedDir: "torch_models",
		},
		{
			name: "ckpts_directory",
			setupFunc: func() {
				modelDir := filepath.Join(paths.CkptsPath, ttsConfig.Model)
				os.MkdirAll(modelDir, 0755)
			},
			expectPath:  true,
			expectedDir: "ckpts",
		},
		{
			name: "torch_models_with_extension",
			setupFunc: func() {
				modelFile := filepath.Join(paths.TorchModels, ttsConfig.Model+".pth")
				os.WriteFile(modelFile, []byte("fake model"), 0644)
			},
			expectPath:  true,
			expectedDir: "torch_models",
		},
		{
			name: "ckpts_with_extension",
			setupFunc: func() {
				modelFile := filepath.Join(paths.CkptsPath, ttsConfig.Model+".bin")
				os.WriteFile(modelFile, []byte("fake model"), 0644)
			},
			expectPath:  true,
			expectedDir: "ckpts",
		},
	}
	
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Clean up from previous tests
			os.RemoveAll(paths.TorchModels)
			os.RemoveAll(paths.CkptsPath)
			os.MkdirAll(paths.TorchModels, 0755)
			os.MkdirAll(paths.CkptsPath, 0755)
			
			// Setup test conditions
			tt.setupFunc()
			
			result := engine.getModelPath()
			
			if tt.expectPath {
				if result == "" {
					t.Error("Expected model path but got empty string")
				} else if !strings.Contains(result, tt.expectedDir) {
					t.Errorf("Expected path to contain '%s', got: %s", tt.expectedDir, result)
				}
				
				// Verify path actually exists
				if _, err := os.Stat(result); os.IsNotExist(err) {
					t.Errorf("Model path does not exist: %s", result)
				}
			} else {
				if result != "" {
					t.Errorf("Expected empty path but got: %s", result)
				}
			}
		})
	}
}