// Package main provides a command-line interface for native Go text-to-speech conversion.
//
// This command processes JSON chunk files from the chunking system and converts
// them to audio files using native Go TTS implementation (no Python dependencies).
// It integrates seamlessly with the existing book expert pipeline.
//
// Usage:
//   text-to-speech [options] <chunks-file> <output-dir>
//
// Examples:
//   text-to-speech data/pdf-name/chunks.json output/pdf-name/wav
//   text-to-speech --model "E2TTS_Base" chunks.json wav/
//
// The command will:
// 1. Read configuration from project.toml
// 2. Load text chunks from the JSON file
// 3. Convert each chunk to a WAV audio file using native Go TTS
// 4. Save audio files in the output directory with names like chunk_0001.wav
//
// Native Go implementation features:
// - No Python dependencies
// - Built-in neural network inference
// - Configurable GPU memory management
// - Parallel processing optimized for chunked text
package main

import (
	"book-expert/internal/config"
	"book-expert/internal/logging"
	"book-expert/internal/tts"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"
)

// Version information
var (
	version   = "dev"
	buildTime = "unknown"
	gitHash   = "unknown"
)

// Command-line flags
var (
	configPath  = flag.String("config", "project.toml", "Path to configuration file")
	modelName   = flag.String("model", "", "TTS model to use (overrides config)")
	workers     = flag.Int("workers", 0, "Number of parallel workers (overrides config)")
	useGPU      = flag.Bool("gpu", true, "Enable GPU processing")
	verbose     = flag.Bool("verbose", false, "Enable verbose logging")
	showVersion = flag.Bool("version", false, "Show version information")
	showHelp    = flag.Bool("help", false, "Show help message")
)

func main() {
	flag.Parse()

	// Handle special flags
	if *showVersion {
		fmt.Printf("text-to-speech %s (built %s, commit %s)\n", version, buildTime, gitHash)
		return
	}

	if *showHelp {
		showUsage()
		return
	}

	// Find project root and configuration (following existing pattern)
	wd, err := os.Getwd()
	if err != nil {
		log.Fatalf("Failed to get working directory: %v", err)
	}

	root, cfgPath, err := config.FindProjectRoot(wd)
	if err != nil {
		log.Fatalf("Failed to find project root: %v", err)
	}

	// Override config path if provided
	if *configPath != "project.toml" {
		cfgPath = *configPath
	}

	// Load configuration
	cfg, err := config.Load(cfgPath)
	if err != nil {
		log.Fatalf("Failed to load configuration: %v", err)
	}

	// Initialize logging in project structure
	logDir := filepath.Join(root, "logs", "tts")
	logger, err := logging.New(logDir, "text-to-speech.log")
	if err != nil {
		log.Fatalf("Failed to initialize logger: %v", err)
	}
	defer logger.Close()

	logger.Info("Loading configuration from %s", cfgPath)

	// Determine input and output paths
	var chunksFile, outputDir string
	
	if flag.NArg() == 2 {
		// Manual paths provided
		chunksFile = flag.Arg(0)
		outputDir = flag.Arg(1)
	} else if flag.NArg() == 0 {
		// Auto-discover from configuration (following existing pattern)
		chunksFile, outputDir = discoverPaths(cfg, root, logger)
	} else {
		showUsage()
		return
	}

	// Apply command-line overrides
	if *modelName != "" {
		cfg.TTSSettings.Model = *modelName
		logger.Info("Using model from command line: %s", *modelName)
	}
	if *workers > 0 {
		cfg.TTSSettings.Workers = *workers
		logger.Info("Using %d workers from command line", *workers)
	}
	cfg.TTSSettings.UseGPU = *useGPU

	// Validate input file
	if _, err := os.Stat(chunksFile); os.IsNotExist(err) {
		log.Fatalf("Chunks file does not exist: %s", chunksFile)
	}

	// Ensure output directory exists
	if err := os.MkdirAll(outputDir, 0755); err != nil {
		log.Fatalf("Failed to create output directory %s: %v", outputDir, err)
	}

	// Initialize TTS engine
	logger.Info("Initializing native Go TTS engine with model: %s", cfg.TTSSettings.Model)
	logger.Info("GPU enabled: %t, Memory limit: %.1f GB, Workers: %d", 
		cfg.TTSSettings.UseGPU, cfg.TTSSettings.GPUMemoryLimitGB, cfg.TTSSettings.Workers)

	engine, err := tts.NewEngine(cfg)
	if err != nil {
		log.Fatalf("Failed to initialize TTS engine: %v", err)
	}

	// Process chunks
	logger.Info("Processing chunks from %s to %s", chunksFile, outputDir)
	startTime := time.Now()

	err = engine.ProcessChunks(chunksFile, outputDir)
	if err != nil {
		log.Fatalf("TTS processing failed: %v", err)
	}

	duration := time.Since(startTime)
	logger.Info("TTS processing completed successfully in %v", duration)

	// Count generated files
	files, err := filepath.Glob(filepath.Join(outputDir, "chunk_*.wav"))
	if err != nil {
		logger.Warn("Failed to count output files: %v", err)
	} else {
		logger.Info("Generated %d audio files", len(files))
	}
}

// discoverPaths automatically finds chunks.json files and determines output paths
func discoverPaths(cfg config.Config, root string, logger *logging.Logger) (string, string) {
	// Look for chunks.json files in the data directory structure
	dataDir := cfg.Paths.OutputDir
	if dataDir == "" {
		dataDir = filepath.Join(root, "data")
	}

	var chunksFiles []string
	
	// Find all chunks.json files
	err := filepath.Walk(dataDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil // Continue walking on errors
		}
		if info.Name() == "chunks.json" {
			chunksFiles = append(chunksFiles, path)
		}
		return nil
	})

	if err != nil || len(chunksFiles) == 0 {
		log.Fatalf("No chunks.json files found in %s. Run chunk-text first or provide manual paths.", dataDir)
	}

	// Use the most recent chunks file
	var mostRecent string
	var mostRecentTime time.Time
	
	for _, file := range chunksFiles {
		if info, err := os.Stat(file); err == nil {
			if info.ModTime().After(mostRecentTime) {
				mostRecent = file
				mostRecentTime = info.ModTime()
			}
		}
	}

	if mostRecent == "" {
		log.Fatalf("Could not determine most recent chunks file from: %v", chunksFiles)
	}

	// Determine output directory based on chunks file location
	chunkDir := filepath.Dir(mostRecent)
	outputDir := filepath.Join(chunkDir, "wav") // Create wav subdirectory

	logger.Info("Auto-discovered chunks file: %s", mostRecent)
	logger.Info("Audio output directory: %s", outputDir)

	return mostRecent, outputDir
}

// showUsage displays help information
func showUsage() {
	fmt.Fprintf(os.Stderr, `text-to-speech - Convert text chunks to speech

USAGE:
    text-to-speech [options] [chunks-file] [output-dir]

ARGUMENTS (optional):
    <chunks-file>    Path to JSON file containing text chunks (auto-discovered if omitted)
    <output-dir>     Directory to save generated audio files (auto-determined if omitted)

OPTIONS:
    -config PATH     Configuration file path (default: project.toml)
    -model NAME      TTS model name (overrides config)
    -workers N       Number of parallel workers (overrides config)  
    -gpu             Enable GPU processing (default: true)
    -verbose         Enable verbose logging
    -version         Show version information
    -help            Show this help message

EXAMPLES:
    # Auto-discovery (recommended) - finds most recent chunks.json
    text-to-speech

    # Manual paths
    text-to-speech data/book/chunks.json output/book/wav

    # Auto-discovery with custom model
    text-to-speech -model "tts_models/multilingual/multi-dataset/xtts_v2"

    # Disable GPU and use 4 workers
    text-to-speech -gpu=false -workers 4

    # Verbose logging with auto-discovery
    text-to-speech -verbose

CONFIGURATION:
    The command reads TTS settings from project.toml:
    - Model name and GPU memory limits
    - Python environment path
    - Model directories (torch_models, ckpts)
    - Worker count and timeout settings

OUTPUT:
    Generates WAV files named chunk_0001.wav, chunk_0002.wav, etc.
    Each file corresponds to one text chunk from the input JSON.

MODELS:
    - Local models are searched in torch_models/ and ckpts/ directories
    - If no local model found, downloads from Coqui TTS model zoo
    - Supports all Coqui TTS model formats (.pth, .pt, .bin, .safetensors)

GPU MEMORY:
    Automatically manages GPU memory usage based on configured limits.
    Default limit is 5.5GB but can be adjusted in project.toml.
`)
}