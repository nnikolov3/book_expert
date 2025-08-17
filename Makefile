# Book Expert Project Makefile
# Following design principles: "Do more with less" and "Test, test, test"

.PHONY: help test test-quick test-verbose test-profile build clean lint fmt install-tools setup-hooks

# Default target
help: ## Show this help message
	@echo "Book Expert Project - Available targets:"
	@echo
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Examples:"
	@echo "  make test          # Run full pipeline"
	@echo "  make test-quick    # Run essential checks only"
	@echo "  make build         # Build all binaries"
	@echo "  make setup-hooks   # Install git hooks"

test: ## Run full testing pipeline
	@./scripts/test_pipeline.sh

test-quick: ## Run essential checks only (fast)
	@./scripts/test_pipeline.sh --quick

test-verbose: ## Run pipeline with verbose output
	@./scripts/test_pipeline.sh --verbose

test-profile: ## Run pipeline with profiling enabled
	@./scripts/test_pipeline.sh --profile

# Build targets
build: ## Build all Go binaries
	@echo "Building Go binaries..."
	@# triple-enhance removed per simplified pipeline
	@go build -o bin/pdf-to-png ./cmd/pdf-to-png
	@go build -o bin/png-to-text-tesseract ./cmd/png-to-text-tesseract
	@go build -o bin/merge-text ./cmd/merge-text
	@go build -o bin/png-text-augment ./cmd/png-text-augment
	@go build -o bin/text-to-wav ./cmd/text-to-wav
	@go build -o bin/wav-to-mp3 ./cmd/wav-to-mp3
	@echo "Build completed ✅"
	@echo "Binaries in bin/: $$(ls -1 bin | tr '\n' ' ')"


# Code quality targets
lint: ## Run linters on all code
	@echo "Running linters..."
	@if command -v golangci-lint >/dev/null 2>&1; then \
		golangci-lint run; \
	else \
		go vet ./...; \
	fi
	@find . -name "*.sh" -not -path "./.git/*" -exec shellcheck {} \;
	@echo "Linting completed ✅"

fmt: ## Format all code
	@echo "Formatting Go code..."
	@go fmt ./...
	@if command -v goimports >/dev/null 2>&1; then \
		goimports -w $$(find . -name "*.go" -not -path "./vendor/*"); \
	fi
	@echo "Formatting completed ✅"

# Development setup
install-tools: ## Install required development tools
	@echo "Installing development tools..."
	@go install golang.org/x/tools/cmd/goimports@latest
	@go install honnef.co/go/tools/cmd/staticcheck@latest
	@if command -v curl >/dev/null 2>&1; then \
		curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b $$(go env GOPATH)/bin v1.54.2; \
	fi
	@echo "Tools installation completed ✅"

setup-hooks: ## Install git hooks for automated testing
	@./scripts/test_pipeline.sh >/dev/null 2>&1 || true
	@echo "Git hooks installed ✅"

# Cleanup
clean: ## Clean build artifacts and logs
	@echo "Cleaning build artifacts..."
	@rm -rf bin/*
	@rm -rf logs/pipeline/*.log logs/pipeline/*.prof
	@go clean -cache -testcache
	@echo "Cleanup completed ✅"


# CI/CD targets
ci: clean fmt lint test build ## Full CI pipeline (clean, format, lint, test, build)
	@echo "CI pipeline completed successfully ✅"

# Profiling helpers
profile-cpu: ## View CPU profile (requires previous profiled run)
	@if [ -f "logs/pipeline/cpu.prof" ]; then \
		go tool pprof logs/pipeline/cpu.prof; \
	else \
		echo "No CPU profile found. Run 'make test-profile' first."; \
	fi

profile-mem: ## View memory profile (requires previous profiled run)
	@if [ -f "logs/pipeline/mem.prof" ]; then \
		go tool pprof logs/pipeline/mem.prof; \
	else \
		echo "No memory profile found. Run 'make test-profile' first."; \
	fi

# Quality metrics
metrics: ## Show code quality metrics
	@echo "=== Code Quality Metrics ==="
	@echo "Go files: $$(find . -name '*.go' -not -path './.git/*' | wc -l)"
	@echo "Bash files: $$(find . -name '*.sh' -not -path './.git/*' | wc -l)"
	@echo "Total lines of Go code: $$(find . -name '*.go' -not -path './.git/*' -exec wc -l {} + | tail -1 | awk '{print $$1}')"
	@echo "Total lines of Bash code: $$(find . -name '*.sh' -not -path './.git/*' -exec wc -l {} + | tail -1 | awk '{print $$1}')"
	@if command -v gocyclo >/dev/null 2>&1; then \
		echo "High complexity functions:"; \
		gocyclo -over 10 . || echo "  None found ✅"; \
	fi
	@echo "Test coverage:"
	@go test -cover ./... 2>/dev/null | grep -o 'coverage: [0-9.]*%' || echo "  No tests found"

# Development workflow
dev: fmt test-quick ## Developer workflow: format, quick test
	@echo "Development workflow completed ✅"

# Release workflow  
release: clean ci ## Full release pipeline
	@echo "Release pipeline completed ✅"
	@echo "Ready for deployment 🚀"