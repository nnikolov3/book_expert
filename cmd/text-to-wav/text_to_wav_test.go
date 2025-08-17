package main

import (
	"bufio"
	"strings"
	"testing"
)

func TestChunkText_BasicAndBoundaries(t *testing.T) {
	text := "line1\n\nline2\nline3\n\nline4"
	chunks := chunkText(text, 6)
	if len(chunks) == 0 {
		t.Fatalf("expected chunks")
	}
	for _, c := range chunks {
		if len(c) > 6 {
			t.Errorf("chunk too long: %d", len(c))
		}
	}

	// Ensure no empty chunks
	for i, c := range chunks {
		if strings.TrimSpace(c) == "" {
			t.Errorf("empty chunk at %d", i)
		}
	}

	// Scanner split should be by lines
	s := bufio.NewScanner(strings.NewReader(text))
	s.Split(bufio.ScanLines)
	lineCount := 0
	for s.Scan() {
		if strings.TrimSpace(s.Text()) != "" {
			lineCount++
		}
	}
	if lineCount == 0 {
		t.Fatalf("expected non-zero lines")
	}
}
