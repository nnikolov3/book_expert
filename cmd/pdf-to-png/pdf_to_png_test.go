package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestDiscoverPDFs_AndCountFiles(t *testing.T) {
	dir := t.TempDir()
	files := []string{"a.pdf", "b.PDF", "c.txt"}
	for _, name := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("x"), 0o644); err != nil {
			t.Fatalf("write file: %v", err)
		}
	}

	paths, err := discoverPDFs(dir)
	if err != nil {
		t.Fatalf("discoverPDFs: %v", err)
	}
	if len(paths) != 2 {
		t.Fatalf("discoverPDFs len=%d, want 2", len(paths))
	}

	// Count by extension
	countPDF, err := countFiles(dir, ".pdf")
	if err != nil {
		t.Fatalf("countFiles .pdf: %v", err)
	}
	if countPDF != 2 {
		t.Errorf("countFiles(.pdf)=%d, want 2", countPDF)
	}
	countTXT, err := countFiles(dir, ".txt")
	if err != nil {
		t.Fatalf("countFiles .txt: %v", err)
	}
	if countTXT != 1 {
		t.Errorf("countFiles(.txt)=%d, want 1", countTXT)
	}
}

func TestDiscoverPDFs(t *testing.T) {
	tests := []struct {
		name          string
		files         []string
		expectedCount int
		expectedPaths []string
	}{
		{
			name:          "empty directory",
			files:         []string{},
			expectedCount: 0,
			expectedPaths: []string{},
		},
		{
			name:          "no PDF files",
			files:         []string{"readme.txt", "image.jpg", "data.csv"},
			expectedCount: 0,
			expectedPaths: []string{},
		},
		{
			name:          "single PDF",
			files:         []string{"document.pdf"},
			expectedCount: 1,
			expectedPaths: []string{"document.pdf"},
		},
		{
			name:          "mixed case PDFs",
			files:         []string{"doc1.pdf", "doc2.PDF", "Doc3.Pdf", "readme.txt"},
			expectedCount: 3,
			expectedPaths: []string{"doc1.pdf", "doc2.PDF", "Doc3.Pdf"},
		},
		{
			name:          "PDFs with special characters",
			files:         []string{"file-name.pdf", "file_name.pdf", "file name.pdf"},
			expectedCount: 3,
			expectedPaths: []string{"file-name.pdf", "file_name.pdf", "file name.pdf"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dir := t.TempDir()

			// Create test files
			for _, filename := range tt.files {
				filePath := filepath.Join(dir, filename)
				err := os.WriteFile(filePath, []byte("test content"), 0644)
				require.NoError(t, err)
			}

			result, err := discoverPDFs(dir)

			assert.NoError(t, err)
			assert.Len(t, result, tt.expectedCount)

			// Check that all expected PDFs are found (as full paths)
			for _, expectedFile := range tt.expectedPaths {
				expectedPath := filepath.Join(dir, expectedFile)
				assert.Contains(t, result, expectedPath)
			}
		})
	}
}

func TestDiscoverPDFs_NonExistentDirectory(t *testing.T) {
	nonExistentDir := "/path/that/does/not/exist"

	result, err := discoverPDFs(nonExistentDir)

	assert.Error(t, err)
	assert.Nil(t, result)
}

func TestCountFiles(t *testing.T) {
	tests := []struct {
		name          string
		files         []string
		extension     string
		expectedCount int
	}{
		{
			name:          "count PDF files",
			files:         []string{"doc1.pdf", "doc2.PDF", "doc3.txt", "image.jpg"},
			extension:     ".pdf",
			expectedCount: 2,
		},
		{
			name:          "count TXT files",
			files:         []string{"doc1.txt", "doc2.TXT", "doc3.pdf", "image.jpg"},
			extension:     ".txt",
			expectedCount: 2,
		},
		{
			name:          "no matching files",
			files:         []string{"doc1.pdf", "doc2.txt", "image.jpg"},
			extension:     ".png",
			expectedCount: 0,
		},
		{
			name:          "empty directory",
			files:         []string{},
			extension:     ".pdf",
			expectedCount: 0,
		},
		{
			name:          "case insensitive matching",
			files:         []string{"doc.PDF", "doc.pdf", "doc.Pdf"},
			extension:     ".PDF",
			expectedCount: 3, // Case insensitive - all should match
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dir := t.TempDir()

			// Create test files
			for _, filename := range tt.files {
				filePath := filepath.Join(dir, filename)
				err := os.WriteFile(filePath, []byte("test content"), 0644)
				require.NoError(t, err)
			}

			result, err := countFiles(dir, tt.extension)

			assert.NoError(t, err)
			assert.Equal(t, tt.expectedCount, result)
		})
	}
}

func TestCountFiles_NonExistentDirectory(t *testing.T) {
	nonExistentDir := "/path/that/does/not/exist"

	result, err := countFiles(nonExistentDir, ".pdf")

	assert.Error(t, err)
	assert.Equal(t, 0, result)
}

func TestMustGetwd(t *testing.T) {
	// This function should return the current working directory without error
	// Since it panics on error, we can't easily test error conditions
	result := mustGetwd()

	assert.NotEmpty(t, result)
	assert.True(t, filepath.IsAbs(result), "Working directory should be absolute path")
}

func TestGetPDFPages_ErrorConditions(t *testing.T) {
	tests := []struct {
		name     string
		filePath string
		wantErr  bool
	}{
		{
			name:     "non-existent file",
			filePath: "/path/that/does/not/exist.pdf",
			wantErr:  true,
		},
		{
			name:     "empty file path",
			filePath: "",
			wantErr:  true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := getPDFPages(tt.filePath)

			if tt.wantErr {
				assert.Error(t, err)
				assert.Equal(t, 0, result)
			} else {
				assert.NoError(t, err)
				assert.Greater(t, result, 0)
			}
		})
	}
}

func TestRenderPage_ErrorConditions(t *testing.T) {
	tests := []struct {
		name    string
		pdfPath string
		page    int
		dpi     int
		output  string
		wantErr bool
	}{
		{
			name:    "non-existent PDF",
			pdfPath: "/path/that/does/not/exist.pdf",
			page:    1,
			dpi:     200,
			output:  "/tmp/output.png",
			wantErr: true,
		},
		{
			name:    "invalid page number",
			pdfPath: "/some/file.pdf",
			page:    0,
			dpi:     200,
			output:  "/tmp/output.png",
			wantErr: true,
		},
		{
			name:    "invalid output path",
			pdfPath: "/some/file.pdf",
			page:    1,
			dpi:     200,
			output:  "",
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 1*time.Second)
			defer cancel()

			err := renderPage(ctx, tt.pdfPath, tt.page, tt.dpi, tt.output)

			if tt.wantErr {
				assert.Error(t, err)
			} else {
				assert.NoError(t, err)
			}
		})
	}
}

func TestIsBlankFast_ErrorConditions(t *testing.T) {
	tests := []struct {
		name        string
		pngPath     string
		fuzzPercent int
		threshold   float64
		expectErr   bool
	}{
		{
			name:        "non-existent file - external command handles validation",
			pngPath:     "/path/that/does/not/exist.png",
			fuzzPercent: 5,
			threshold:   0.005,
			expectErr:   true, // External command should fail
		},
		{
			name:        "valid parameters format",
			pngPath:     "/some/file.png",
			fuzzPercent: 5,
			threshold:   0.005,
			expectErr:   true, // File doesn't exist, but format is valid
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, _ := isBlankFast(tt.pngPath, tt.fuzzPercent, tt.threshold)

			// The function itself doesn't validate inputs - it passes them to external command
			// We expect errors when the external command fails (e.g., file not found)
			if tt.expectErr {
				// External command should fail, function may return error
				assert.False(t, result) // Should return false when external command fails
			}
			// Note: We don't assert on err because the behavior depends on external command availability
		})
	}
}

// Integration test for PDF discovery in subdirectories
func TestDiscoverPDFs_NestedDirectories(t *testing.T) {
	dir := t.TempDir()

	// Create nested structure
	subDir1 := filepath.Join(dir, "subdir1")
	subDir2 := filepath.Join(dir, "subdir2")
	err := os.MkdirAll(subDir1, 0755)
	require.NoError(t, err)
	err = os.MkdirAll(subDir2, 0755)
	require.NoError(t, err)

	// Create files in different locations
	files := map[string]string{
		filepath.Join(dir, "root.pdf"):     "root pdf",
		filepath.Join(subDir1, "sub1.pdf"): "sub1 pdf",
		filepath.Join(subDir2, "sub2.PDF"): "sub2 pdf",
		filepath.Join(dir, "readme.txt"):   "readme",
	}

	for filePath, content := range files {
		err := os.WriteFile(filePath, []byte(content), 0644)
		require.NoError(t, err)
	}

	// Test - should only find files in the root directory, not subdirectories
	result, err := discoverPDFs(dir)

	assert.NoError(t, err)
	assert.Len(t, result, 1) // Only root.pdf should be found
	assert.Contains(t, result, filepath.Join(dir, "root.pdf"))
	assert.NotContains(t, result, filepath.Join(subDir1, "sub1.pdf"))
	assert.NotContains(t, result, filepath.Join(subDir2, "sub2.PDF"))
}

// Benchmark tests for performance monitoring
func BenchmarkDiscoverPDFs(b *testing.B) {
	dir := b.TempDir()

	// Create many PDF files
	for i := 0; i < 100; i++ {
		filename := filepath.Join(dir, fmt.Sprintf("document_%d.pdf", i))
		_ = os.WriteFile(filename, []byte("content"), 0644)
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = discoverPDFs(dir)
	}
}

func BenchmarkCountFiles(b *testing.B) {
	dir := b.TempDir()

	// Create many files of different types
	for i := 0; i < 100; i++ {
		pdfFile := filepath.Join(dir, fmt.Sprintf("document_%d.pdf", i))
		txtFile := filepath.Join(dir, fmt.Sprintf("document_%d.txt", i))
		_ = os.WriteFile(pdfFile, []byte("content"), 0644)
		_ = os.WriteFile(txtFile, []byte("content"), 0644)
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = countFiles(dir, ".pdf")
	}
}
