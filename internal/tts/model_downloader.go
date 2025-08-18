// Package tts - Model downloader for Coqui TTS models
//
// Downloads and manages TTS model files from Hugging Face Hub
// Supports XTTS v2 and other Coqui TTS models for native Go usage

package tts

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// ModelDownloader handles downloading TTS models from Hugging Face
type ModelDownloader struct {
	cacheDir string
	client   *http.Client
}

// ModelInfo contains metadata about downloadable models
type ModelManifest struct {
	Name        string            `json:"name"`
	HFRepo      string            `json:"hf_repo"`      // Hugging Face repository
	Files       []ModelFile       `json:"files"`        // Required files
	Description string            `json:"description"`
	Language    []string          `json:"language"`
	Dataset     string            `json:"dataset"`
	License     string            `json:"license"`
	Contact     string            `json:"contact"`
}

// ModelFile represents a file that needs to be downloaded
type ModelFile struct {
	Name     string `json:"name"`
	URL      string `json:"url"`
	Size     int64  `json:"size"`
	Checksum string `json:"checksum"` // SHA256
}

// NewModelDownloader creates a new model downloader
func NewModelDownloader(cacheDir string) *ModelDownloader {
	return &ModelDownloader{
		cacheDir: cacheDir,
		client:   &http.Client{},
	}
}

// GetXTTSv2Manifest returns the manifest for XTTS v2 model
func (d *ModelDownloader) GetXTTSv2Manifest() ModelManifest {
	return ModelManifest{
		Name:        "xtts_v2",
		HFRepo:      "coqui/XTTS-v2",
		Description: "XTTS v2 - Multilingual voice cloning model (24kHz, 17 languages, 6-second voice cloning)",
		Language:    []string{"en", "es", "fr", "de", "it", "pt", "pl", "tr", "ru", "nl", "cs", "ar", "zh-cn", "ja", "hu", "ko", "hi"},
		Dataset:     "multi-dataset",
		License:     "Coqui Public Model License",
		Contact:     "info@coqui.ai",
		Files: []ModelFile{
			{
				Name: "config.json",
				URL:  "https://huggingface.co/coqui/XTTS-v2/resolve/main/config.json",
				Size: 4370, // 4.37 kB
			},
			{
				Name: "model.pth",
				URL:  "https://huggingface.co/coqui/XTTS-v2/resolve/main/model.pth",
				Size: 1870000000, // 1.87 GB - main model weights
			},
			{
				Name: "dvae.pth",
				URL:  "https://huggingface.co/coqui/XTTS-v2/resolve/main/dvae.pth",
				Size: 211000000, // 211 MB - decoder/VAE component
			},
			{
				Name: "vocab.json", 
				URL:  "https://huggingface.co/coqui/XTTS-v2/resolve/main/vocab.json",
				Size: 361000, // 361 kB
			},
			{
				Name: "speakers_xtts.pth",
				URL:  "https://huggingface.co/coqui/XTTS-v2/resolve/main/speakers_xtts.pth",
				Size: 7750000, // 7.75 MB - speaker embeddings
			},
			{
				Name: "mel_stats.pth",
				URL:  "https://huggingface.co/coqui/XTTS-v2/resolve/main/mel_stats.pth",
				Size: 1070, // 1.07 kB - mel spectrogram statistics
			},
		},
	}
}

// DownloadModel downloads a complete model to the cache directory
func (d *ModelDownloader) DownloadModel(manifest ModelManifest) (string, error) {
	modelDir := filepath.Join(d.cacheDir, manifest.Name)
	
	// Create model directory
	if err := os.MkdirAll(modelDir, 0755); err != nil {
		return "", fmt.Errorf("failed to create model directory: %w", err)
	}

	// Download each file
	for _, file := range manifest.Files {
		filePath := filepath.Join(modelDir, file.Name)
		
		// Skip if file already exists and is valid
		if d.isFileValid(filePath, file.Checksum) {
			fmt.Printf("File already exists: %s\n", file.Name)
			continue
		}

		fmt.Printf("Downloading %s...\n", file.Name)
		err := d.downloadFile(file.URL, filePath)
		if err != nil {
			return "", fmt.Errorf("failed to download %s: %w", file.Name, err)
		}

		// Verify checksum if provided
		if file.Checksum != "" && !d.isFileValid(filePath, file.Checksum) {
			return "", fmt.Errorf("checksum mismatch for %s", file.Name)
		}
	}

	fmt.Printf("Model %s downloaded successfully to %s\n", manifest.Name, modelDir)
	return modelDir, nil
}

// downloadFile downloads a single file from URL to destination with progress
func (d *ModelDownloader) downloadFile(url, dest string) error {
	// Create destination file
	out, err := os.Create(dest)
	if err != nil {
		return fmt.Errorf("failed to create file: %w", err)
	}
	defer out.Close()

	// Download file
	resp, err := d.client.Get(url)
	if err != nil {
		return fmt.Errorf("failed to download: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download failed: %s", resp.Status)
	}

	// Get content length for progress tracking
	contentLength := resp.ContentLength
	
	// Copy with progress reporting for large files
	if contentLength > 10*1024*1024 { // Show progress for files > 10MB
		written, err := d.copyWithProgress(out, resp.Body, contentLength, filepath.Base(dest))
		if err != nil {
			return fmt.Errorf("failed to save file: %w", err)
		}
		fmt.Printf("Downloaded %s: %d bytes\n", filepath.Base(dest), written)
	} else {
		_, err = io.Copy(out, resp.Body)
		if err != nil {
			return fmt.Errorf("failed to save file: %w", err)
		}
	}

	return nil
}

// copyWithProgress copies data while showing download progress
func (d *ModelDownloader) copyWithProgress(dst io.Writer, src io.Reader, total int64, filename string) (int64, error) {
	var written int64
	buf := make([]byte, 32*1024) // 32KB buffer
	
	lastProgress := 0
	for {
		nr, er := src.Read(buf)
		if nr > 0 {
			nw, ew := dst.Write(buf[0:nr])
			if nw < 0 || nr < nw {
				nw = 0
				if ew == nil {
					ew = fmt.Errorf("invalid write result")
				}
			}
			written += int64(nw)
			if ew != nil {
				return written, ew
			}
			if nr != nw {
				return written, fmt.Errorf("short write")
			}
			
			// Show progress every 10%
			if total > 0 {
				progress := int((written * 100) / total)
				if progress >= lastProgress+10 {
					fmt.Printf("Downloading %s: %d%% (%d/%d MB)\n", 
						filename, progress, written/(1024*1024), total/(1024*1024))
					lastProgress = progress
				}
			}
		}
		if er != nil {
			if er != io.EOF {
				return written, er
			}
			break
		}
	}
	return written, nil
}

// isFileValid checks if a file exists and matches the expected checksum
func (d *ModelDownloader) isFileValid(filePath, expectedChecksum string) bool {
	if expectedChecksum == "" {
		// No checksum provided, just check existence
		_, err := os.Stat(filePath)
		return err == nil
	}

	file, err := os.Open(filePath)
	if err != nil {
		return false
	}
	defer file.Close()

	hash := sha256.New()
	_, err = io.Copy(hash, file)
	if err != nil {
		return false
	}

	actualChecksum := hex.EncodeToString(hash.Sum(nil))
	return strings.EqualFold(actualChecksum, expectedChecksum)
}

// EnsureModelAvailable downloads model if not present, returns path to model directory
func (d *ModelDownloader) EnsureModelAvailable(modelName string) (string, error) {
	switch {
	case strings.Contains(modelName, "xtts_v2"):
		manifest := d.GetXTTSv2Manifest()
		return d.DownloadModel(manifest)
	default:
		return "", fmt.Errorf("unsupported model: %s", modelName)
	}
}

// ListAvailableModels returns list of models that can be downloaded
func (d *ModelDownloader) ListAvailableModels() []string {
	return []string{
		"tts_models/multilingual/multi-dataset/xtts_v2",
		// Add more models as we implement them
	}
}