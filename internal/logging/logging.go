package logging

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sync"
)

// Logger provides leveled, thread-safe logging to stdout and a rotating file per run.
// Keep this simple and dependency-free.
type Logger struct {
	mu      sync.Mutex
	logFile *os.File
	std     *log.Logger
	file    *log.Logger
}

func New(logDir string, filename string) (*Logger, error) {
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		return nil, fmt.Errorf("create log dir: %w", err)
	}
	logPath := filepath.Join(logDir, filename)
	f, err := os.OpenFile(logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, fmt.Errorf("open log file: %w", err)
	}
	return &Logger{
		logFile: f,
		std:     log.New(os.Stdout, "", log.LstdFlags),
		file:    log.New(f, "", log.LstdFlags),
	}, nil
}

func (l *Logger) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.logFile != nil {
		err := l.logFile.Close()
		l.logFile = nil
		return err
	}
	return nil
}

func (l *Logger) Info(format string, args ...any)    { l.write("INFO", format, args...) }
func (l *Logger) Warn(format string, args ...any)    { l.write("WARN", format, args...) }
func (l *Logger) Error(format string, args ...any)   { l.write("ERROR", format, args...) }
func (l *Logger) Success(format string, args ...any) { l.write("PASS", format, args...) }

func (l *Logger) write(level string, format string, args ...any) {
	l.mu.Lock()
	defer l.mu.Unlock()
	msg := fmt.Sprintf("[%s] %s", level, fmt.Sprintf(format, args...))
	l.std.Println(msg)
	l.file.Println(msg)
}
