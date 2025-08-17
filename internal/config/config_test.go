package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoad_ConfigParsesAndErrors(t *testing.T) {
	// Create a temporary TOML config
	dir := t.TempDir()
	configPath := filepath.Join(dir, "project.toml")
	content := strings.TrimSpace(`
[project]
name = "BookExpert"
version = "1.0.0"

[paths]
input_dir = "/tmp/in"
output_dir = "/tmp/out"
`)
	if err := os.WriteFile(configPath, []byte(content), 0o644); err != nil {
		t.Fatalf("write temp config: %v", err)
	}

	cfg, err := Load(configPath)
	if err != nil {
		t.Fatalf("Load() error: %v", err)
	}
	if cfg.Project.Name != "BookExpert" {
		t.Errorf("Project.Name = %q, want %q", cfg.Project.Name, "BookExpert")
	}
	if cfg.Paths.InputDir != "/tmp/in" || cfg.Paths.OutputDir != "/tmp/out" {
		t.Errorf("Paths parsed incorrectly: %+v", cfg.Paths)
	}

	// Missing file should error
	if _, err := Load(filepath.Join(dir, "missing.toml")); err == nil {
		t.Errorf("Load() expected error for missing file")
	}
}

func TestFindProjectRoot_FindsUpwardAndErrors(t *testing.T) {
	root := t.TempDir()
	nested := filepath.Join(root, "a", "b", "c")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatalf("mkdir nested: %v", err)
	}
	proj := filepath.Join(root, "project.toml")
	if err := os.WriteFile(proj, []byte("[project]\nname='x'\n"), 0o644); err != nil {
		t.Fatalf("write project.toml: %v", err)
	}

	dir, path, err := FindProjectRoot(nested)
	if err != nil {
		t.Fatalf("FindProjectRoot() error: %v", err)
	}
	if dir != root {
		t.Errorf("dir = %q, want %q", dir, root)
	}
	if path != proj {
		t.Errorf("path = %q, want %q", path, proj)
	}

	// Directory tree without project.toml should error
	noProj := t.TempDir()
	if _, _, err := FindProjectRoot(noProj); err == nil {
		t.Errorf("FindProjectRoot() expected error when project.toml is absent")
	}
}
