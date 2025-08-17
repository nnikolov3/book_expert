package logging

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLogger_WritesToStdoutAndFile(t *testing.T) {
	logDir := t.TempDir()
	logger, err := New(logDir, "test.log")
	if err != nil {
		t.Fatalf("New logger: %v", err)
	}
	defer logger.Close()

	logger.Info("hello %s", "world")
	logger.Warn("warn %d", 42)
	logger.Error("err %v", 1)
	logger.Success("ok")

	// Verify file content contains the messages and levels
	path := filepath.Join(logDir, "test.log")
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("open log file: %v", err)
	}
	defer f.Close()

	s := bufio.NewScanner(f)
	var lines []string
	for s.Scan() {
		lines = append(lines, s.Text())
	}
	if err := s.Err(); err != nil {
		t.Fatalf("scan: %v", err)
	}
	joined := strings.Join(lines, "\n")
	for _, want := range []string{"[INFO] hello world", "[WARN] warn 42", "[ERROR] err 1", "[PASS] ok"} {
		if !strings.Contains(joined, want) {
			t.Errorf("log file missing %q; got:\n%s", want, joined)
		}
	}
}

func TestLogger_CloseIdempotent(t *testing.T) {
	logDir := t.TempDir()
	logger, err := New(logDir, "test2.log")
	if err != nil {
		t.Fatalf("New logger: %v", err)
	}
	if err := logger.Close(); err != nil {
		t.Fatalf("first close: %v", err)
	}
	// Second close should be safe
	if err := logger.Close(); err != nil {
		t.Fatalf("second close: %v", err)
	}
}
