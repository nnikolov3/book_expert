package chunking

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestNewChunker(t *testing.T) {
	tests := []struct {
		name        string
		config      Config
		shouldPanic bool
	}{
		{
			name:        "valid config",
			config:      Config{TargetSize: 100, MaxSize: 150, MinSize: 30},
			shouldPanic: false,
		},
		{
			name:        "invalid: target > max",
			config:      Config{TargetSize: 200, MaxSize: 150, MinSize: 30},
			shouldPanic: true,
		},
		{
			name:        "invalid: min >= target",
			config:      Config{TargetSize: 100, MaxSize: 150, MinSize: 100},
			shouldPanic: true,
		},
		{
			name:        "invalid: zero values",
			config:      Config{TargetSize: 0, MaxSize: 150, MinSize: 30},
			shouldPanic: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if tt.shouldPanic {
				assert.Panics(t, func() { NewChunker(tt.config) })
			} else {
				assert.NotPanics(t, func() { NewChunker(tt.config) })
			}
		})
	}
}

func TestSplitSentences(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected []string
	}{
		{
			name:     "empty input",
			input:    "",
			expected: nil,
		},
		{
			name:     "single sentence",
			input:    "This is a simple sentence.",
			expected: []string{"This is a simple sentence."},
		},
		{
			name:     "multiple sentences",
			input:    "First sentence. Second sentence! Third sentence?",
			expected: []string{"First sentence.", "Second sentence!", "Third sentence?"},
		},
		{
			name:     "abbreviations should not split",
			input:    "Dr. Smith went to St. Mary's hospital. He met Prof. Johnson there.",
			expected: []string{"Dr. Smith went to St. Mary's hospital.", "He met Prof. Johnson there."},
		},
		{
			name:     "decimal numbers should not split",
			input:    "The value is 3.14159. This is important.",
			expected: []string{"The value is 3.14159.", "This is important."},
		},
		{
			name:     "mixed punctuation",
			input:    "Really? Yes! That's amazing. I agree completely.",
			expected: []string{"Really?", "Yes!", "That's amazing.", "I agree completely."},
		},
		{
			name:     "no ending punctuation",
			input:    "This sentence has no punctuation",
			expected: []string{"This sentence has no punctuation"},
		},
		{
			name:     "whitespace variations",
			input:    "First.   Second.    Third.",
			expected: []string{"First.", "Second.", "Third."},
		},
		{
			name:     "e.g. and i.e. abbreviations",
			input:    "Many animals (e.g. cats, dogs) are pets. Some are wild (i.e. lions, tigers).",
			expected: []string{"Many animals (e.g. cats, dogs) are pets.", "Some are wild (i.e. lions, tigers)."},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := splitSentences(tt.input)
			assert.Equal(t, tt.expected, result, "Input: %q", tt.input)
		})
	}
}

func TestCleanText(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{
			name:     "empty input",
			input:    "",
			expected: "",
		},
		{
			name:     "remove references",
			input:    "This is text [1] with references [2] and more [123].",
			expected: "This is text with references and more .",
		},
		{
			name:     "remove citations",
			input:    "Smith et al. (2023) found that results (Johnson, 2022) were significant.",
			expected: "found that results were significant.",
		},
		{
			name:     "normalize whitespace",
			input:    "Too    many   \t\n  spaces.",
			expected: "Too many spaces.",
		},
		{
			name:     "preserve URLs and emails",
			input:    "Visit https://example.com or email test@example.com for more info.",
			expected: "Visit https://example.com or email test@example.com for more info.",
		},
		{
			name:     "complex mixed content",
			input:    "Research [1] shows\n\nthat    performance   improves. See https://research.com (Smith, 2023).",
			expected: "Research shows that performance improves. See https://research.com .",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := cleanText(tt.input)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestChunkText(t *testing.T) {
	cfg := Config{TargetSize: 50, MaxSize: 80, MinSize: 20}
	chunker := NewChunker(cfg)

	tests := []struct {
		name         string
		input        string
		expectMin    int
		expectMax    int
		checkLengths bool
	}{
		{
			name:         "short sentences stay together",
			input:        "Short. Also short. Very short too.",
			expectMin:    1,
			expectMax:    1,
			checkLengths: true,
		},
		{
			name:         "long sentence gets split",
			input:        "This is a very long sentence that should definitely be split into smaller chunks because it exceeds our maximum size limit and needs to be broken down.",
			expectMin:    2,
			expectMax:    4,
			checkLengths: true,
		},
		{
			name:         "mixed short and long",
			input:        "Short. This is a much longer sentence that should be split. Another short one.",
			expectMin:    1,
			expectMax:    3,
			checkLengths: false, // Don't check lengths for this mixed case
		},
		{
			name:         "empty input",
			input:        "",
			expectMin:    0,
			expectMax:    0,
			checkLengths: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := chunker.chunkText(tt.input)

			// Check number of chunks
			assert.GreaterOrEqual(t, len(result), tt.expectMin, "Too few chunks")
			assert.LessOrEqual(t, len(result), tt.expectMax, "Too many chunks")

			if tt.checkLengths {
				// Check chunk sizes
				for i, chunk := range result {
					assert.LessOrEqual(t, len(chunk), cfg.MaxSize, "Chunk %d too long: %q", i, chunk)
					// Only enforce min size if we have multiple chunks AND the total input was longer than target
					if len(result) > 1 && len(tt.input) > cfg.TargetSize {
						assert.GreaterOrEqual(t, len(chunk), cfg.MinSize, "Chunk %d too short: %q", i, chunk)
					}
				}
			}
		})
	}
}

func TestChunkFile(t *testing.T) {
	// Create temporary test file
	tempDir := t.TempDir()
	inputFile := filepath.Join(tempDir, "test.txt")
	outputDir := filepath.Join(tempDir, "output")

	content := "This is the first sentence. This is a much longer second sentence that contains more content and should be processed correctly. Short third."
	err := os.WriteFile(inputFile, []byte(content), 0644)
	require.NoError(t, err)

	// Create output directory structure
	pdfDir := filepath.Join(outputDir, "test_pdf")
	err = os.MkdirAll(pdfDir, 0755)
	require.NoError(t, err)

	cfg := Config{TargetSize: 50, MaxSize: 80, MinSize: 20}
	chunker := NewChunker(cfg)

	// Test successful chunking
	err = chunker.ChunkFile(inputFile, outputDir, "test_pdf")
	assert.NoError(t, err)

	// Verify output file exists
	outputFile := filepath.Join(pdfDir, "chunks.json")
	assert.FileExists(t, outputFile)

	// Verify content is valid JSON
	data, err := os.ReadFile(outputFile)
	require.NoError(t, err)
	assert.True(t, strings.HasPrefix(string(data), "["))
	assert.True(t, strings.HasSuffix(strings.TrimSpace(string(data)), "]"))
}

func TestChunkFile_Errors(t *testing.T) {
	cfg := Config{TargetSize: 50, MaxSize: 80, MinSize: 20}
	chunker := NewChunker(cfg)

	// Test with non-existent file
	err := chunker.ChunkFile("/non/existent/file.txt", "/tmp", "test")
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "failed to open")
}

func TestIsSentenceBoundary(t *testing.T) {
	tests := []struct {
		name     string
		text     string
		pos      int
		expected bool
	}{
		{
			name:     "period at end",
			text:     "Hello.",
			pos:      5,
			expected: true,
		},
		{
			name:     "abbreviation Dr.",
			text:     "Dr. Smith",
			pos:      2,
			expected: false,
		},
		{
			name:     "decimal number",
			text:     "Value 3.14 here",
			pos:      7,
			expected: false,
		},
		{
			name:     "exclamation mark",
			text:     "Wow! That's great",
			pos:      3,
			expected: true,
		},
		{
			name:     "question mark",
			text:     "Really? I think so",
			pos:      6,
			expected: true,
		},
		{
			name:     "period before lowercase",
			text:     "Hello. world",
			pos:      5,
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			runes := []rune(tt.text)
			result := isSentenceBoundary(runes, tt.pos)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func BenchmarkChunkText(b *testing.B) {
	cfg := Config{TargetSize: 150, MaxSize: 200, MinSize: 50}
	chunker := NewChunker(cfg)

	// Create a reasonably long text for benchmarking
	text := strings.Repeat("This is a sentence for benchmarking purposes. ", 1000)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		chunker.chunkText(text)
	}
}

func BenchmarkSplitSentences(b *testing.B) {
	text := strings.Repeat("This is a sentence for benchmarking purposes. ", 1000)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		splitSentences(text)
	}
}

func BenchmarkCleanText(b *testing.B) {
	text := "This text [1] has references [2] and citations (Smith, 2023) that need cleaning. " +
		"It also has    extra   whitespace\n\nand other issues to resolve."
	text = strings.Repeat(text, 100)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		cleanText(text)
	}
}
