package main

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestListPDFBaseNames(t *testing.T) {
	tests := []struct {
		name          string
		files         []string
		expectedCount int
		expectedNames []string
	}{
		{
			name:          "empty directory",
			files:         []string{},
			expectedCount: 0,
			expectedNames: []string{},
		},
		{
			name:          "no PDF files",
			files:         []string{"readme.txt", "config.json", "image.png"},
			expectedCount: 0,
			expectedNames: []string{},
		},
		{
			name:          "single PDF file",
			files:         []string{"document.pdf"},
			expectedCount: 1,
			expectedNames: []string{"document"},
		},
		{
			name:          "multiple PDF files with mixed case",
			files:         []string{"doc1.pdf", "doc2.PDF", "Doc3.Pdf", "readme.txt"},
			expectedCount: 3,
			expectedNames: []string{"doc1", "doc2", "Doc3"},
		},
		{
			name:          "PDFs with complex names",
			files:         []string{"Research_Paper_2023.pdf", "meeting-notes.pdf", "file with spaces.pdf"},
			expectedCount: 3,
			expectedNames: []string{"Research_Paper_2023", "meeting-notes", "file with spaces"},
		},
		{
			name:          "mixed file types",
			files:         []string{"doc.pdf", "image.jpg", "data.csv", "backup.tar.gz", "report.PDF"},
			expectedCount: 2,
			expectedNames: []string{"doc", "report"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Create temporary directory
			dir := t.TempDir()

			// Create test files
			for _, filename := range tt.files {
				filePath := filepath.Join(dir, filename)
				err := os.WriteFile(filePath, []byte("test content"), 0644)
				require.NoError(t, err, "Failed to create test file: %s", filename)
			}

			// Test the function
			result, err := listPDFBaseNames(dir)

			// Assertions
			assert.NoError(t, err)
			assert.Len(t, result, tt.expectedCount, "Unexpected number of PDF base names")

			if tt.expectedCount > 0 {
				// Check that all expected names are present (order may vary)
				for _, expectedName := range tt.expectedNames {
					assert.Contains(t, result, expectedName, "Expected base name not found: %s", expectedName)
				}
			}
		})
	}
}

func TestListPDFBaseNames_NonExistentDirectory(t *testing.T) {
	nonExistentDir := "/path/that/does/not/exist"

	result, err := listPDFBaseNames(nonExistentDir)

	assert.Error(t, err)
	assert.Nil(t, result)
	assert.Contains(t, err.Error(), "no such file or directory")
}

func TestListPDFBaseNames_EmptyDirectory(t *testing.T) {
	dir := t.TempDir()

	result, err := listPDFBaseNames(dir)

	assert.NoError(t, err)
	assert.Empty(t, result)
}

func TestListPDFBaseNames_DirectoryWithSubdirectories(t *testing.T) {
	dir := t.TempDir()

	// Create some files and subdirectories
	files := []string{"doc1.pdf", "doc2.pdf"}
	for _, filename := range files {
		filePath := filepath.Join(dir, filename)
		err := os.WriteFile(filePath, []byte("test content"), 0644)
		require.NoError(t, err)
	}

	// Create a subdirectory with a PDF (should be ignored)
	subDir := filepath.Join(dir, "subdir")
	err := os.MkdirAll(subDir, 0755)
	require.NoError(t, err)

	subPdfPath := filepath.Join(subDir, "subdoc.pdf")
	err = os.WriteFile(subPdfPath, []byte("test content"), 0644)
	require.NoError(t, err)

	result, err := listPDFBaseNames(dir)

	assert.NoError(t, err)
	assert.Len(t, result, 2)
	assert.Contains(t, result, "doc1")
	assert.Contains(t, result, "doc2")
	assert.NotContains(t, result, "subdoc") // Should not include PDFs from subdirectories
}

func TestListPDFBaseNames_SpecialCharacters(t *testing.T) {
	dir := t.TempDir()

	// Test files with special characters
	files := []string{
		"file-with-dashes.pdf",
		"file_with_underscores.pdf",
		"file with spaces.pdf",
		"file(with)parentheses.pdf",
		"file[with]brackets.pdf",
		"file&with&symbols.pdf",
	}

	for _, filename := range files {
		filePath := filepath.Join(dir, filename)
		err := os.WriteFile(filePath, []byte("test content"), 0644)
		require.NoError(t, err)
	}

	result, err := listPDFBaseNames(dir)

	assert.NoError(t, err)
	assert.Len(t, result, len(files))

	// Check that base names are correctly extracted
	expectedNames := []string{
		"file-with-dashes",
		"file_with_underscores",
		"file with spaces",
		"file(with)parentheses",
		"file[with]brackets",
		"file&with&symbols",
	}

	for _, expectedName := range expectedNames {
		assert.Contains(t, result, expectedName)
	}
}

func TestListPDFBaseNames_CaseInsensitive(t *testing.T) {
	dir := t.TempDir()

	// Test various case combinations
	files := []string{
		"document.pdf",
		"DOCUMENT2.PDF",
		"Document3.Pdf",
		"dOcUmEnT4.PdF",
	}

	for _, filename := range files {
		filePath := filepath.Join(dir, filename)
		err := os.WriteFile(filePath, []byte("test content"), 0644)
		require.NoError(t, err)
	}

	result, err := listPDFBaseNames(dir)

	assert.NoError(t, err)
	assert.Len(t, result, 4)

	expectedNames := []string{"document", "DOCUMENT2", "Document3", "dOcUmEnT4"}
	for _, expectedName := range expectedNames {
		assert.Contains(t, result, expectedName)
	}
}

// Benchmark test for performance
func BenchmarkListPDFBaseNames(b *testing.B) {
	// Create temporary directory with many files
	dir := b.TempDir()

	// Create 100 PDF files and 100 other files
	for i := 0; i < 100; i++ {
		pdfPath := filepath.Join(dir, fmt.Sprintf("document_%d.pdf", i))
		otherPath := filepath.Join(dir, fmt.Sprintf("file_%d.txt", i))

		_ = os.WriteFile(pdfPath, []byte("content"), 0644)
		_ = os.WriteFile(otherPath, []byte("content"), 0644)
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = listPDFBaseNames(dir)
	}
}
