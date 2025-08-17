package main

import (
	"os"
	"path/filepath"
	"testing"
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
