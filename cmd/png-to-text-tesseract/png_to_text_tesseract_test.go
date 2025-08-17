package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestListPDFBaseNames(t *testing.T) {
	dir := t.TempDir()
	files := []string{"a.pdf", "b.PDF", "readme.md"}
	for _, f := range files {
		if err := os.WriteFile(filepath.Join(dir, f), []byte("x"), 0o644); err != nil {
			t.Fatalf("write: %v", err)
		}
	}

	names, err := listPDFBaseNames(dir)
	if err != nil {
		t.Fatalf("listPDFBaseNames: %v", err)
	}
	if len(names) != 2 {
		t.Fatalf("got %d names, want 2", len(names))
	}
}

func TestFindPNGsSorted(t *testing.T) {
	dir := t.TempDir()
	files := []string{"page_0002.png", "page_0001.PNG", "note.txt"}
	for _, f := range files {
		if err := os.WriteFile(filepath.Join(dir, f), []byte("x"), 0o644); err != nil {
			t.Fatalf("write: %v", err)
		}
	}

	list, err := findPNGsSorted(dir)
	if err != nil {
		t.Fatalf("findPNGsSorted: %v", err)
	}
	if len(list) != 2 {
		t.Fatalf("len=%d, want 2", len(list))
	}
	if filepath.Base(list[0]) != "page_0001.PNG" || filepath.Base(list[1]) != "page_0002.png" {
		t.Errorf("unexpected sort order: %v", list)
	}
}
