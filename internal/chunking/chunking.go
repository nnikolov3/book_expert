// Package chunking provides natural speech chunking for text-to-speech (TTS) applications.
//
// It splits text into sentences and clauses to preserve natural flow, using configurable sizes.
// Chunks are written as JSON for downstream processing (e.g., TTS APIs).
// References like [1] are removed during normalization for smoother speech.
//
// Follows DESIGN_PRINCIPLES_GUIDE.md (simplicity, explicitness, modularity) and
// GO_CODING_STANDARD.md (explicit error handling, naming conventions, clarity).
//
// Usage example:
//
//	cfg := chunking.Config{TargetSize: 150, MaxSize: 200, MinSize: 50}
//	chunker := chunking.NewChunker(cfg)
//	err := chunker.ChunkFile("input.txt", "output/dir", "example.pdf")
//	if err != nil {
//	    // Handle error.
//	}
package chunking

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"unicode"
)

// Precompiled regex patterns for improved performance and sentence detection
var (
	// Common abbreviations that shouldn't trigger sentence breaks
	abbreviationRegex = regexp.MustCompile(`(?i)\b(?:dr|mr|mrs|ms|prof|ph\.d|m\.d|b\.a|m\.a|etc|e\.g|i\.e|vs|cf|ca|inc|ltd|corp|co|dept|vol|no|pp|fig|ref|al|st|ave|blvd|rd|str|jr|sr)\.$`)

	// Multiple whitespace normalization
	multiWhitespaceRegex = regexp.MustCompile(`\s+`)

	// Enhanced reference patterns: [1], (1), ¹, footnotes, etc.
	referencesRegex = regexp.MustCompile(`(?:\[\d+\]|\(\d+\)|[¹²³⁴⁵⁶⁷⁸⁹⁰]+|\b\d+\s*\.\s*$)`)

	// Citation patterns like "Smith et al. (2023)" or "(Smith, 2023)"
	citationRegex = regexp.MustCompile(`\([^)]*\d{4}[^)]*\)|\b\w+\s+et\s+al\.`)

	// URL and email patterns to preserve
	urlEmailRegex = regexp.MustCompile(`https?://[^\s]+|[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}`)
)

// Config holds explicit chunking parameters (e.g., from TOML or environment).
// All sizes are in characters and must satisfy: MinSize < TargetSize <= MaxSize.
type Config struct {
	TargetSize int // Ideal chunk size for TTS (e.g., 150 characters).
	MaxSize    int // Hard maximum to avoid API limits (e.g., 200 characters).
	MinSize    int // Minimum to merge tiny chunks (e.g., 50 characters).
}

// Chunker performs text chunking with the given configuration.
type Chunker struct {
	cfg Config
}

// NewChunker creates a chunker with explicit validation.
// Panics if config is invalid to fail fast (per explicitness principle).
func NewChunker(cfg Config) *Chunker {
	if cfg.TargetSize <= 0 || cfg.MaxSize <= 0 || cfg.MinSize <= 0 {
		panic("invalid config: sizes must be positive")
	}
	if cfg.MinSize >= cfg.TargetSize || cfg.TargetSize > cfg.MaxSize {
		panic("invalid config: min < target <= max required")
	}
	return &Chunker{cfg: cfg}
}

// ChunkFile reads inputFile, normalizes and cleans the text (removing references), chunks it naturally,
// and writes to outputDir/pdf/chunks.json.
// Returns an error if file operations fail, with wrapped context.
func (c *Chunker) ChunkFile(inputFile, outputDir, pdf string) error {
	text, err := readText(inputFile)
	if err != nil {
		return err // Already wrapped in readText.
	}

	// Clean and normalize for consistent, TTS-friendly text.
	text = cleanText(text)

	chunks := c.chunkText(text)

	outputPath := filepath.Join(outputDir, pdf, "chunks.json")
	return writeChunks(outputPath, chunks)
}

// readText loads file content.
// Returns the raw text or a wrapped error if reading fails.
func readText(file string) (string, error) {
	f, err := os.Open(file)
	if err != nil {
		return "", fmt.Errorf("failed to open %s: %w", file, err)
	}
	defer f.Close()

	bytes, err := io.ReadAll(f)
	if err != nil {
		return "", fmt.Errorf("failed to read %s: %w", file, err)
	}

	return string(bytes), nil
}

// normalizeWhitespace collapses multiple spaces, normalizes line breaks, and trims the text.
// Handles various Unicode whitespace characters for robust processing.
func normalizeWhitespace(text string) string {
	if text == "" {
		return text
	}
	// Replace various whitespace with standard space
	text = multiWhitespaceRegex.ReplaceAllString(text, " ")
	// Clean up common formatting issues
	text = strings.ReplaceAll(text, "\r\n", " ")
	text = strings.ReplaceAll(text, "\n", " ")
	text = strings.ReplaceAll(text, "\t", " ")
	return strings.TrimSpace(text)
}

// cleanText performs comprehensive text cleaning for better TTS output.
// Removes references, citations, and normalizes formatting while preserving meaning.
func cleanText(text string) string {
	if text == "" {
		return text
	}

	// Preserve URLs and emails temporarily
	urlPlaceholders := make(map[string]string)
	urlMatches := urlEmailRegex.FindAllString(text, -1)
	for i, match := range urlMatches {
		placeholder := fmt.Sprintf("__URL_PLACEHOLDER_%d__", i)
		urlPlaceholders[placeholder] = match
		text = strings.Replace(text, match, placeholder, 1)
	}

	// Remove references and citations
	text = referencesRegex.ReplaceAllString(text, "")
	text = citationRegex.ReplaceAllString(text, "")

	// Normalize whitespace
	text = normalizeWhitespace(text)

	// Restore URLs and emails
	for placeholder, original := range urlPlaceholders {
		text = strings.Replace(text, placeholder, original, 1)
	}

	return text
}

// removeReferences strips citation markers like [1] from the text.
// This is kept for backward compatibility but cleanText is preferred.
func removeReferences(text string) string {
	return referencesRegex.ReplaceAllString(text, "")
}

// chunkText splits the text into natural TTS chunks.
// First splits into sentences, then handles long sentences, then merges small ones.
func (c *Chunker) chunkText(text string) []string {
	sentences := splitSentences(text)
	var chunks []string
	for _, sentence := range sentences {
		chunks = append(chunks, splitLongSentence(sentence, c.cfg.MaxSize)...)
	}
	return mergeSmallChunks(chunks, c.cfg.MinSize, c.cfg.TargetSize)
}

// splitSentences breaks text on natural sentence ends while avoiding common false positives.
// Handles abbreviations, decimals, and other edge cases for better TTS chunking.
func splitSentences(text string) []string {
	if text == "" {
		return nil
	}

	var sentences []string
	runes := []rune(text)
	start := 0

	for i := 0; i < len(runes); i++ {
		char := runes[i]

		// Check for sentence-ending punctuation
		if char == '.' || char == '!' || char == '?' {
			// Check if this is likely a sentence boundary
			if isSentenceBoundary(runes, i) {
				sentence := strings.TrimSpace(string(runes[start : i+1]))
				if sentence != "" {
					sentences = append(sentences, sentence)
				}

				// Find next non-whitespace character to start new sentence
				nextIdx := i + 1
				for nextIdx < len(runes) && unicode.IsSpace(runes[nextIdx]) {
					nextIdx++
				}
				start = nextIdx
				i = nextIdx - 1 // -1 because loop will increment
			}
		}
	}

	// Handle remaining text
	if start < len(runes) {
		sentence := strings.TrimSpace(string(runes[start:]))
		if sentence != "" {
			sentences = append(sentences, sentence)
		}
	}

	return sentences
}

// isSentenceBoundary determines if a punctuation mark represents a true sentence boundary.
// Considers abbreviations, numbers, and other common false positives.
func isSentenceBoundary(runes []rune, pos int) bool {
	if pos >= len(runes) {
		return true
	}

	char := runes[pos]

	// For ! and ?, usually sentence boundaries unless in special contexts
	if char == '!' || char == '?' {
		// Skip if followed by more punctuation (e.g., "?!" or "!!!")
		next := pos + 1
		if next < len(runes) && (runes[next] == '!' || runes[next] == '?') {
			return false
		}
		return true
	}

	// For periods, need more careful analysis
	if char == '.' {
		// Check for abbreviations by looking at preceding word
		wordStart := pos - 1
		for wordStart >= 0 && !unicode.IsSpace(runes[wordStart]) {
			wordStart--
		}
		wordStart++ // Move to start of word

		if wordStart < pos {
			word := string(runes[wordStart : pos+1])
			if abbreviationRegex.MatchString(word) {
				return false
			}
		}

		// Check for decimal numbers (e.g., "3.14")
		if pos > 0 && pos < len(runes)-1 {
			if unicode.IsDigit(runes[pos-1]) && unicode.IsDigit(runes[pos+1]) {
				return false
			}
		}

		// Check if next character suggests continuation
		next := pos + 1
		if next < len(runes) {
			nextChar := runes[next]

			// If followed by lowercase letter, probably not sentence boundary
			if unicode.IsLower(nextChar) {
				return false
			}

			// If followed by space then lowercase, likely not sentence boundary
			if unicode.IsSpace(nextChar) && next+1 < len(runes) && unicode.IsLower(runes[next+1]) {
				return false
			}
		}

		return true
	}

	return false
}

// splitLongSentence sub-splits a sentence on clauses (e.g., ,, ;, :) if over maxSize.
// Returns one or more chunks, each <= maxSize, preserving natural breaks.
// Falls back to word-splitting if a part exceeds maxSize (e.g., long unpunctuated text).
// This avoids duplicates by using explicit index-based slicing.
func splitLongSentence(sentence string, maxSize int) []string {
	if len(sentence) <= maxSize {
		return []string{sentence}
	}

	// Delimiter regex for clause breaks (explicit, no magic).
	delimiterRe := regexp.MustCompile(`[,;:]`)

	// Find all delimiter positions.
	locs := delimiterRe.FindAllStringIndex(sentence, -1)

	var results []string
	var buffer strings.Builder
	start := 0

	// Append end-of-sentence as a virtual delimiter for completeness.
	locs = append(locs, []int{len(sentence), len(sentence)})

	for _, loc := range locs {
		// Slice up to and including the delimiter.
		end := loc[1] // End after delimiter.
		part := sentence[start:end]

		// If adding exceeds max and buffer has content, flush.
		if buffer.Len()+len(part) > maxSize && buffer.Len() > 0 {
			results = append(results, strings.TrimSpace(buffer.String()))
			buffer.Reset()
		}

		buffer.WriteString(part)
		start = end
	}

	// Flush remaining buffer.
	if buffer.Len() > 0 {
		results = append(results, strings.TrimSpace(buffer.String()))
	}

	// Safety pass: Force-split any over-max chunks (e.g., long words without punctuation).
	var final []string
	for _, chunk := range results {
		if len(chunk) <= maxSize {
			final = append(final, chunk)
			continue
		}
		// Split on spaces, accumulating until max.
		words := strings.Split(chunk, " ")
		buf := strings.Builder{}
		for _, word := range words {
			if buf.Len() > 0 && buf.Len()+len(word)+1 > maxSize {
				final = append(final, strings.TrimSpace(buf.String()))
				buf.Reset()
			}
			if buf.Len() > 0 {
				buf.WriteString(" ")
			}
			buf.WriteString(word)
		}
		if buf.Len() > 0 {
			final = append(final, strings.TrimSpace(buf.String()))
		}
	}

	return final
}

// mergeSmallChunks combines tiny chunks for smoother TTS.
// Merges if under minSize and combined <= targetSize.
// Uses a buffer for efficient string building.
func mergeSmallChunks(chunks []string, minSize, targetSize int) []string {
	if len(chunks) == 0 {
		return chunks
	}

	var merged []string
	var buffer strings.Builder

	for _, chunk := range chunks {
		// If buffer is empty, always add the chunk
		if buffer.Len() == 0 {
			buffer.WriteString(chunk)
			continue
		}

		// Check if we can merge this chunk with the buffer
		combinedLen := buffer.Len() + 1 + len(chunk) // +1 for space
		if combinedLen <= targetSize {
			buffer.WriteString(" " + chunk)
			continue
		}

		// Can't merge, so flush buffer and start new one
		merged = append(merged, buffer.String())
		buffer.Reset()
		buffer.WriteString(chunk)
	}

	// Don't forget the last buffer
	if buffer.Len() > 0 {
		merged = append(merged, buffer.String())
	}

	// Final pass: Merge undersized chunks if possible
	// Only apply minSize rule if we have multiple chunks
	if len(merged) > 1 {
		i := 0
		for i < len(merged)-1 {
			currentLen := len(merged[i])
			nextLen := len(merged[i+1])
			combinedLen := currentLen + 1 + nextLen

			// Merge if current chunk is too small OR if both are small and can combine
			shouldMerge := (currentLen < minSize && combinedLen <= targetSize) ||
				(currentLen < minSize && nextLen < minSize && combinedLen <= targetSize)

			if shouldMerge {
				merged[i] = merged[i] + " " + merged[i+1]
				merged = append(merged[:i+1], merged[i+2:]...)
				// Don't increment i, recheck this position
			} else {
				i++
			}
		}
	}

	return merged
}

// writeChunks saves chunks as indented JSON.
// Returns a wrapped error if marshaling or writing fails.
func writeChunks(path string, chunks []string) error {
	data, err := json.MarshalIndent(chunks, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal chunks: %w", err)
	}
	if err := os.WriteFile(path, data, 0644); err != nil {
		return fmt.Errorf("failed to write %s: %w", path, err)
	}
	return nil
}
