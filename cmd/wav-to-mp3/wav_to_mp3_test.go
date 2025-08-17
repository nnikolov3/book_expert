package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestListWavsSorted(t *testing.T) {
	dir := t.TempDir()
	files := []string{"chunk_0002.wav", "chunk_0001.WAV", "note.txt"}
	for _, f := range files {
		if err := os.WriteFile(filepath.Join(dir, f), []byte("x"), 0o644); err != nil {
			t.Fatalf("write: %v", err)
		}
	}

	list, err := listWavsSorted(dir)
	if err != nil {
		t.Fatalf("listWavsSorted: %v", err)
	}
	if len(list) != 2 {
		t.Fatalf("len=%d, want 2", len(list))
	}
	// Verify order
	if filepath.Base(list[0]) != "chunk_0001.WAV" || filepath.Base(list[1]) != "chunk_0002.wav" {
		t.Errorf("unexpected order: %v", list)
	}
}
