package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestMainHelp tests the help functionality
func TestMainHelp(t *testing.T) {
	tests := []struct {
		name string
		args []string
	}{
		{
			name: "help_flag",
			args: []string{"-help"},
		},
		{
			name: "no_arguments",
			args: []string{},
		},
		{
			name: "insufficient_arguments",
			args: []string{"chunks.json"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Build the command
			cmd := exec.Command("go", append([]string{"run", "main.go"}, tt.args...)...)
			cmd.Dir = filepath.Dir(".")

			output, err := cmd.CombinedOutput()
			outputStr := string(output)

			// Help should exit cleanly or show usage
			if !strings.Contains(outputStr, "text-to-speech - Convert text chunks to speech") &&
				!strings.Contains(outputStr, "USAGE:") {
				t.Errorf("Expected help output, got: %s", outputStr)
			}

			// Should mention key usage elements
			expectedStrings := []string{"chunks-file", "output-dir", "OPTIONS"}
			for _, expected := range expectedStrings {
				if !strings.Contains(outputStr, expected) {
					t.Errorf("Expected help to contain '%s', got: %s", expected, outputStr)
				}
			}
		})
	}
}

// TestMainVersion tests the version functionality
func TestMainVersion(t *testing.T) {
	cmd := exec.Command("go", "run", "main.go", "-version")
	cmd.Dir = filepath.Dir(".")

	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Errorf("Version command failed: %v\nOutput: %s", err, string(output))
	}

	outputStr := string(output)
	if !strings.Contains(outputStr, "text-to-speech") {
		t.Errorf("Expected version output to contain 'text-to-speech', got: %s", outputStr)
	}
}

// TestMainWithValidConfig tests the main function with a valid configuration
func TestMainWithValidConfig(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping integration test in short mode")
	}

	tempDir := t.TempDir()

	// Create test config file
	configContent := `
[project]
name = "test-book-expert"
version = "0.0.1"

[paths]
python_path = "/usr/bin"
torch_models = "` + filepath.Join(tempDir, "torch_models") + `"
ckpts_path = "` + filepath.Join(tempDir, "ckpts") + `"

[f5_tts_settings]
model = "test-model"
workers = 1
timeout_duration = 30
gpu_memory_limit_gb = 2.0
use_gpu = false
`
	configPath := filepath.Join(tempDir, "test-config.toml")
	err := os.WriteFile(configPath, []byte(configContent), 0644)
	if err != nil {
		t.Fatalf("Failed to create test config: %v", err)
	}

	// Create test chunks file
	chunksContent := `["Hello world", "This is a test", "Final chunk"]`
	chunksPath := filepath.Join(tempDir, "chunks.json")
	err = os.WriteFile(chunksPath, []byte(chunksContent), 0644)
	if err != nil {
		t.Fatalf("Failed to create test chunks file: %v", err)
	}

	// Create output directory
	outputDir := filepath.Join(tempDir, "output")
	err = os.MkdirAll(outputDir, 0755)
	if err != nil {
		t.Fatalf("Failed to create output directory: %v", err)
	}

	// Create model directories
	err = os.MkdirAll(filepath.Join(tempDir, "torch_models"), 0755)
	if err != nil {
		t.Fatalf("Failed to create torch_models directory: %v", err)
	}
	err = os.MkdirAll(filepath.Join(tempDir, "ckpts"), 0755)
	if err != nil {
		t.Fatalf("Failed to create ckpts directory: %v", err)
	}

	// Run the command (it will fail due to missing Python TTS, but should parse args correctly)
	cmd := exec.Command("go", "run", "main.go",
		"-config", configPath,
		"-verbose",
		chunksPath,
		outputDir)
	cmd.Dir = filepath.Dir(".")

	output, err := cmd.CombinedOutput()
	outputStr := string(output)

	// Should fail at TTS engine initialization, not argument parsing
	if err == nil {
		t.Error("Expected command to fail due to missing TTS, but it succeeded")
	}

	// Should show it got past argument parsing
	if !strings.Contains(outputStr, "Loading configuration from") &&
		!strings.Contains(outputStr, "Failed to initialize TTS engine") &&
		!strings.Contains(outputStr, "python TTS validation failed") {
		t.Errorf("Expected configuration loading message, got: %s", outputStr)
	}
}

// TestMainWithInvalidArgs tests error handling for invalid arguments
func TestMainWithInvalidArgs(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping integration test in short mode")
	}

	tests := []struct {
		name        string
		args        []string
		expectError bool
		errorText   string
	}{
		{
			name:        "nonexistent_chunks_file",
			args:        []string{"/nonexistent/chunks.json", "/tmp/output"},
			expectError: true,
			errorText:   "does not exist",
		},
		{
			name:        "invalid_config_file",
			args:        []string{"-config", "/nonexistent/config.toml", "chunks.json", "output"},
			expectError: true,
			errorText:   "Failed to load configuration",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cmd := exec.Command("go", append([]string{"run", "main.go"}, tt.args...)...)
			cmd.Dir = filepath.Dir(".")

			output, err := cmd.CombinedOutput()
			outputStr := string(output)

			if tt.expectError {
				if err == nil {
					t.Errorf("Expected error but command succeeded. Output: %s", outputStr)
				}
				if !strings.Contains(outputStr, tt.errorText) {
					t.Errorf("Expected error containing '%s', got: %s", tt.errorText, outputStr)
				}
			} else {
				if err != nil {
					t.Errorf("Unexpected error: %v\nOutput: %s", err, outputStr)
				}
			}
		})
	}
}

// TestMainCommandLineOverrides tests command-line parameter overrides
func TestMainCommandLineOverrides(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping integration test in short mode")
	}

	tempDir := t.TempDir()

	// Create minimal config
	configContent := `
[project]
name = "test"

[paths]
python_path = "/usr/bin"
torch_models = "/tmp/torch_models"
ckpts_path = "/tmp/ckpts"

[f5_tts_settings]
model = "default-model"
workers = 1
gpu_memory_limit_gb = 4.0
use_gpu = true
`
	configPath := filepath.Join(tempDir, "config.toml")
	err := os.WriteFile(configPath, []byte(configContent), 0644)
	if err != nil {
		t.Fatalf("Failed to create config: %v", err)
	}

	// Create test chunks
	chunksContent := `["Test chunk"]`
	chunksPath := filepath.Join(tempDir, "chunks.json")
	err = os.WriteFile(chunksPath, []byte(chunksContent), 0644)
	if err != nil {
		t.Fatalf("Failed to create chunks: %v", err)
	}

	outputDir := filepath.Join(tempDir, "output")

	// Test command-line overrides
	cmd := exec.Command("go", "run", "main.go",
		"-config", configPath,
		"-model", "override-model",
		"-workers", "4",
		"-gpu=false",
		"-verbose",
		chunksPath,
		outputDir)
	cmd.Dir = filepath.Dir(".")

	output, err := cmd.CombinedOutput()
	outputStr := string(output)

	// Should show override messages (will fail at TTS init, but that's expected)
	expectedMessages := []string{
		"Using model from command line: override-model",
		"Using 4 workers from command line",
		"GPU enabled: false",
	}

	for _, expected := range expectedMessages {
		if !strings.Contains(outputStr, expected) {
			t.Errorf("Expected output to contain '%s', got: %s", expected, outputStr)
		}
	}
}