# Document-to-Audiobook Pipeline

A restart-safe Go-based pipeline that turns any PDF into a polished, single-file MP3.

## Status

- ✅ **Code Standards Compliant**: Follows Go Coding Standards, Bash Coding Standards, and Design Principles
- ✅ **Fully tested on Fedora 42** (stock repos + RPM Fusion)
- ⚠️ **Untested on Ubuntu** – behavior there is unknown
- 🔧 **TTS layer** powered by the project-specific fork: `https://github.com/nnikolov3/book_expert_f5-tts`

[![Tests](https://img.shields.io/badge/tests-passing-green.svg)](#development-and-testing)
[![Go Report](https://img.shields.io/badge/go%20report-A+-brightgreen.svg)](#development-and-testing)
[![Standards](https://img.shields.io/badge/standards-compliant-blue.svg)](#contributing)

## Pipeline Overview

1. **PDF → PNG**: High-DPI page conversion (`pdf-to-png`)
2. **PNG → OCR**: Text extraction with Tesseract (`png-to-text-tesseract`) 
3. **OCR → Enhanced Text**: LLM-powered narration enhancement (`png-text-augment`)
4. **Text Organization**: Merging and structuring (`merge-text`)
5. **Text → Audio**: TTS synthesis with F5-TTS (`text-to-wav`)
6. **Audio Processing**: WAV → 48kHz mono → MP3 (`wav-to-mp3`)

**Architecture**: Implemented in Go for performance and reliability, with comprehensive configuration management through `project.toml`. Follows modern software engineering practices with extensive testing, linting, and quality assurance.

## Repository Structure

```
book_expert/
├── bin/                      # Compiled Go binaries
├── cmd/                      # Go command implementations
│   ├── pdf-to-png/           # PDF → PNG conversion
│   ├── png-to-text-tesseract/ # OCR processing  
│   ├── png-text-augment/     # LLM enhancement
│   ├── merge-text/           # Text concatenation
│   ├── text-to-wav/          # TTS synthesis
│   └── wav-to-mp3/           # Audio conversion
├── internal/                 # Internal Go packages
│   ├── config/               # Configuration management
│   └── logging/              # Structured logging
├── scripts/                  # Development tools
│   ├── test_pipeline.sh      # Comprehensive testing
│   └── profile_go.sh         # Performance profiling
├── test/                     # Integration tests
├── logs/                     # Pipeline and test logs
├── data/                     # Processing workspace
│   ├── raw/                  # Source PDFs (configurable)
│   └── <pdf_name>/           # Per-document processing
│       ├── png/              # Rendered pages
│       ├── text/             # OCR + enhanced text
│       ├── wav/              # TTS audio chunks
│       └── mp3/              # Final audiobook
├── project.toml              # ★ Complete pipeline configuration ★
├── Makefile                  # Build and test automation
├── go.mod                    # Go module definition
├── DESIGN_PRINCIPLES_GUIDE.md # Development standards
├── GO_CODING_STANDARD.md     # Go coding guidelines
└── README.md                 # This file
```

**Note**: All directory paths are configurable through `project.toml` - nothing is hardcoded.

## Quick Start (Fedora 42)

### 1. System Dependencies

```bash
sudo dnf install \
  ghostscript tesseract tesseract-langpack-eng \
  poppler-utils ImageMagick jq yq rsync ffmpeg \
  shellcheck nproc coreutils awk grep curl flock
```

### 2. F5-TTS Setup

```bash
git clone https://github.com/nnikolov3/book_expert_f5-tts.git
cd book_expert_f5-tts
python -m venv .venv && source .venv/bin/activate
pip install -e .
```

### 3. Project Setup

```bash
git clone https://github.com/<your-org>/book_expert.git
cd book_expert
make build
```

### 4. API Configuration

```bash
export GEMINI_API_KEY="sk-…"      # Google Gemini
export CEREBRAS_API_KEY="cb-…"     # Cerebras inference endpoint
# export NVIDIA_API_KEY="na-…"     # Optional
```

### 5. Configuration

Open **`project.toml`** and adjust:
- `[paths]` / `[directories]` / `[processing_dir]` / `[logs_dir]` – folder layout
- `[settings]` – DPI, `force`, worker counts
- `[google_api]` & `[cerebras_api]` – model names, temps, tokens
- `[f5_tts_settings]` – TTS model, worker threads
- `[prompts.*]` – full system/user prompts used by each LLM call

## Pipeline Components

| Binary | Purpose | Configuration | 
|--------|---------|---------------|
| `pdf-to-png` | PDF → PNG conversion | `settings.dpi`, `settings.*` |
| `png-to-text-tesseract` | OCR text extraction | `tesseract.*` |
| `png-text-augment` | LLM enhancement | `google_api.*`, `prompts.*` |
| `merge-text` | Text concatenation | `text_concatenation.*` |
| `text-to-wav` | TTS synthesis | `f5_tts_settings.*` |
| `wav-to-mp3` | Audio conversion | Audio processing settings |

## Usage

```bash
# Build all binaries
make build

# Run pipeline stages
./bin/pdf-to-png --input data/raw --output data         # PDF → PNG
./bin/png-to-text-tesseract --input data --output data  # PNG → OCR + LLM
./bin/merge-text --input data --output data             # Text → complete.txt
./bin/text-to-wav --input data --output data            # Text → WAV chunks
./bin/wav-to-mp3 --input data --output data             # WAV → MP3
```

**Key Features:**
- 📋 Reads `project.toml` for all configuration and paths
- ❓ Supports `--help` for detailed usage information  
- 🔄 Idempotent operations—safe to rerun; use `--force` to overwrite
- 📊 Comprehensive logging and error reporting
- ⚡ Parallel processing where applicable

## Typical Workflow

1. Drop PDFs into the folder pointed to by `paths.input_dir` (default `data/raw/`).
2. Run `make build` to compile all binaries.
3. Execute the pipeline binaries in order.
4. Find your audiobook at `<output_dir>/<pdf_name>/mp3/<pdf_name>.mp3`.

## Configuration Guide

### Key Configuration Sections in `project.toml`:

- `[paths]`, `[directories]`, `[processing_dir]`, `[logs_dir]` – **all folder locations**
- `[settings]` – DPI, worker counts, force rebuild flag
- `[google_api]`, `[cerebras_api]` – model, temp, tokens, key var names
- `[prompts.*]` – editable multi-paragraph prompts for every LLM stage
- `[f5_tts_settings]` – TTS model name and worker threads
- `[retry]` – global max-retries & back-off seconds

**Dynamic Configuration**: All binaries read configurations at runtime, enabling directory restructuring, model switching, and prompt modifications without recompilation.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| 🔨 Missing binary | Run `make build` or install system dependencies |
| 🔑 Missing API key | Binary indicates required environment variable |
| 🚫 HTTP 429 errors | Automatic retry with exponential backoff |
| 💥 Partial runs/crashes | Rerun binary; completed outputs skipped unless `--force` |
| 🐛 Pipeline issues | Check logs in `logs/` directory |
| 🔍 Debug mode | Use `--verbose` flag for detailed output |

## Development and Testing

### Quick Commands
```bash
make help          # Show all available targets
make build         # Build all binaries
make test          # Run full testing pipeline
make test-quick    # Run essential checks only  
make lint          # Run linters on all code
make fmt           # Format all code
make clean         # Clean build artifacts
make ci            # Full CI pipeline (clean, format, lint, test, build)
```

### Quality Assurance
- ✅ **Comprehensive testing**: Unit tests, integration tests, and performance benchmarks
- 🔍 **Static analysis**: `golangci-lint`, `staticcheck`, `go vet`
- 📏 **Code formatting**: `gofmt`, `goimports` 
- 🔨 **Shell script validation**: `shellcheck` for all Bash scripts
- 📊 **Code coverage**: Tracked and reported
- ⚡ **Performance profiling**: CPU and memory profiling available

### Development Workflow
```bash
make dev           # Quick development cycle (format + test-quick)
make test-profile  # Run tests with profiling enabled
make metrics       # Show code quality metrics
```

## Contributing

### Code Standards
1. **Go Code**: Must pass `go fmt`, `go vet`, and `golangci-lint`
2. **Bash Scripts**: Must pass `shellcheck` validation
3. **Design Principles**: Follow guidelines in `DESIGN_PRINCIPLES_GUIDE.md`
4. **Documentation**: Update `project.toml` docs for new configuration options

### Requirements
- ✅ All new functionality requires tests in `cmd/*/main_test.go`
- ✅ Code must follow the established patterns and conventions
- ✅ PRs must pass the full CI pipeline (`make ci`)
- ✅ Changes should maintain backward compatibility

### Testing Standards
- Unit tests for all public functions
- Integration tests for pipeline components  
- Performance benchmarks for critical paths
- Error case coverage

---

## License

This project follows modern software engineering practices with comprehensive testing, linting, and quality assurance. All code adheres to established coding standards and design principles for maintainability and reliability.