# Document Processing Pipeline

**Note:** The `examples` directory contains examples of converting PDF to an audiobook. *PDFs are for reference and educational purposes only and may not be redistributed.*

This repository provides a robust, modular suite of Bash scripts to convert **PDF documents** into **polished text** and then into a **cohesive audio file (WAV/MP3)**. The workflow uses configurable APIs, parallel processing, and strong error handling, and all major settings are maintained in a single TOML configuration file.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Project Structure](#project-structure)
- [Configuration](#configuration)
- [Setup Instructions](#setup-instructions)
- [Usage](#usage)
- [Pipeline Stages](#pipeline-stages)
- [Code Guidelines](#code-guidelines)


## Prerequisites

Ensure your system provides the following:

- **Bash** (with `set -euo pipefail` support)
- **yq** (for TOML/YAML parsing): `pip install yq`
- **jq** (`apt install jq`)
- **ImageMagick** (for `identify` and image utilities): `sudo apt-get install imagemagick`
- **Ghostscript** (for PDF rasterization): `sudo apt-get install ghostscript`
- **Tesseract OCR**: `sudo apt-get install tesseract-ocr`
- **rsync** (robust file sync): `sudo apt-get install rsync`
- **shellcheck** (bash linter): `sudo apt-get install shellcheck`
- **nproc, flock, sort, awk, base64, curl** (and other standard GNU tools)

API-based functionality requires:

- **Google Gemini API**: Set your API key as an env variable (e.g., `export GEMINI_API_KEY="..."`)
- **NVIDIA AI Cloud API key** (for concept and text correction stages): `export NVIDIA_API_KEY="..."`
- **F5-TTS engine** or compatible engine for TTS inference (ensure it matches your configuration)


## Project Structure

```
book_expert/
├── data/
│   ├── raw/               # PDF input directory / defined in project.toml
│   └── <output_dir>/      # Work/output root, matches config  / defined in project.toml
│       └── <pdf_name>/
│           ├── png/           # PNG images per page
│           ├── text/          # OCR’d page text and concepts
│           ├── polished/      # Polished/narration-ready grouped text
│           ├── concat/        # Concatenated narration-ready text
│           ├── final_concat/  # Output of text cleaning
│           ├── wav/           # TTS-generated .wav files
│           ├── resampled/     # Resampled .wav for uniformity/FFmpeg
│           └── mp3/           # Single-file audiobook output
└── scripts/
    ├── generate_pngs.sh
    ├── generate_page_text.sh
    ├── unify_page_text.sh
    ├── generate_narration_text.sh
    ├── clean_text_helper.sh
    ├── generate_wav.sh
    ├── generate_final_mp3.sh
    └── project.toml
├── README.md
```


## Configuration

**All settings are defined in `project.toml`:**

- `[paths]`: Set `input_dir` (PDFs), `output_dir` (work/output root), and `python_path` for TTS venv
- `[directories]`: Subdirectory layout for each processing stage
- `[processing_dir]` \& `[logs_dir]`: Locations for intermediate and log files (favor fast storage, e.g., `/tmp`)
- `[nvidia_api]` \& `[google_api]` \& `[cerebras_api]`: Model names, endpoints, environment variable key names for API keys
- `[retry]`: Controls retry count and delay for all external API tasks
- `[f5_tts_settings]`: Specifies the TTS model and worker limits

**All absolute paths in `project.toml` must match your environment. API keys must be provided as environment variables before running scripts.**

## Setup Instructions

1. **Clone repository**
```bash
git clone <repository_url>
cd book_expert
```

2. **Install prerequisites**
    - See [Prerequisites](#prerequisites).
    - Install `yq` via `pip` (`pip install yq`).
3. **Configure your environment**
    - Edit `project.toml` to adjust all `[paths]`, `[directories]`, `[api]`, and TTS/model settings to your needs.
    - Set your API keys for Google Gemini, NVIDIA, and Cerebras as environment variables:
```bash
export GEMINI_API_KEY="..."
export NVIDIA_API_KEY="..."
export CEREBRAS_API_KEY="..."
```

4. **Make scripts executable**
```bash
chmod +x scripts/*.sh
```

5. **Prepare input directory**
    - Place all source PDFs in the directory defined by `paths.input_dir` in your `project.toml`.

## Usage

The pipeline is run **sequentially, stage-by-stage**; each script operates on the outputs of the previous.

**Script usage pattern:**

```bash
./scripts/<stage>.sh
```

Execute stages in order. Each script will read `project.toml` and log to its designated directory.

## Pipeline Stages

| Script Name | Input Directory | Output Directory | Function |
| :-- | :-- | :-- | :-- |
| **generate_pngs.sh** | data/raw/ | data/<pdf_name>/png/ | Converts PDF pages to PNG images per page (handles DPI, blank page skipping) |
| **generate_page_text.sh** | data/<pdf_name>/png/ | data/<pdf_name>/text/ | OCR + API: PNG images → narration-ready text \& technical concepts per page |
| **unify_page_text.sh** | data/<pdf_name>/text/ | data/<pdf_name>/polished/ | Groups page text in sets (e.g., 3 at a time), polishes for narration via LLM API |
| **generate_narration_text.sh** | data/<pdf_name>/polished/ | data/<pdf_name>/concat/ | Concatenates narration-ready, polished files into a single narration text file |
| **clean_text_helper.sh** | data/<pdf_name>/concat/ | data/<pdf_name>/final_concat/ | Cleans/normalizes full narration text prior to TTS (acronym, code, math normalization, etc.) |
| **generate_wav.sh** | data/<pdf_name>/final_concat/ | data/<pdf_name>/wav/ | Splits text into semantic chunks, generates WAV per chunk using F5-TTS engine |
| **generate_final_mp3.sh** | data/<pdf_name>/wav/ | data/<pdf_name>/mp3/ | Validates, resamples, orders and merges WAV chunks, produces single .wav and .mp3 audiobook file |

## Code Guidelines

All scripts conform to strict guidelines (see `GUIDELINES_LLM.md`):

- **Declare all variables** prior to assignment
- Use **explicit `if/then/fi`** for clarity
- All files/loops/blocks are properly closed, and error codes are checked
- **Atomic operations:** Use `mv`, `flock`, and safe temp dirs to avoid concurrency issues
- **Dependency checks:** All required binaries and APIs are validated at runtime
- **Retry logic:** All API stages are robust to failure (see `[retry]` in `project.toml`)
- **Logging:** Each stage writes its own log file; terminal output is mirrored to disk
- **No hardcoded values:** All paths/settings use `project.toml`
- *Comments*: Code uses extensive Markdown comments and descriptive variable names

**Note:** For reproducibility, review each script—configuration keys and functions may be updated between versions. Always run scripts in an environment where all dependencies and API keys are set.

<div style="text-align: center">⁂</div>

[^1]: generate_pngs.sh

[^2]: generate_page_text.sh

[^3]: unify_page_text.sh

[^4]: generate_narration_text.sh

[^5]: clean_text_helper.sh

[^6]: generate_wav.sh

[^7]: generate_final_mp3.sh

[^8]: project.toml

[^9]: README.md

Let me know if you need a minimal or a more explanatory version!

<div style="text-align: center">⁂</div>

[^1]: clean_text_helper.sh

[^2]: generate_final_mp3.sh

[^3]: generate_narration_text.sh

[^4]: generate_page_text.sh

[^5]: generate_pngs.sh

[^6]: generate_wav.sh

[^7]: GUIDELINES_LLM.md

[^8]: project.toml

[^9]: README.md

[^10]: unify_page_text.sh

