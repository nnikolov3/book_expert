package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestListAndConcat(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "text")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	files := []struct{ name, content string }{
		{"a.txt", "first"}, {"b.txt", "second"}, {"c.log", "ignored"},
	}
	for _, f := range files {
		if err := os.WriteFile(filepath.Join(dir, f.name), []byte(f.content), 0o644); err != nil {
			t.Fatalf("write: %v", err)
		}
	}

	list, err := listTextFiles(dir)
	if err != nil {
		t.Fatalf("listTextFiles: %v", err)
	}
	if len(list) != 2 {
		t.Fatalf("listTextFiles len=%d, want 2", len(list))
	}

	out := filepath.Join(root, "out.txt")
	if err := concat(list, out); err != nil {
		t.Fatalf("concat: %v", err)
	}
	b, _ := os.ReadFile(out)
	got := string(b)
	if !strings.Contains(got, "first") || !strings.Contains(got, "second") {
		t.Errorf("concat output missing content: %q", got)
	}
}
