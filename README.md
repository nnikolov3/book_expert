<img src="https://r2cdn.perplexity.ai/pplx-full-logo-primary-dark%402x.png" class="logo" width="120"/>

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
- **yq** (for TOML/YAML parsing):
`pip install yq`
- **jq** (`apt install jq`)
- **ImageMagick** (for identify, etc.):
`sudo apt-get install imagemagick`
- **Ghostscript** (for PDF rasterization):
`sudo apt-get install ghostscript`
- **Tesseract OCR** (OCR functionality):
`sudo apt-get install tesseract-ocr`
- **rsync** (robust file sync):
`sudo apt-get install rsync`
- **shellcheck** (bash linter):
`sudo apt-get install shellcheck`
- **nproc, flock, sort, awk, base64, curl** and dependencies as used by the scripts

API-based functionality requires:

- **Google Gemini API**:
Set your API key as an env variable (e.g., `export GEMINI_API_KEY="..."`)
- **NVIDIA AI Cloud API key** (for concept and text correction stages):
`export NVIDIA_API_KEY="..."`
- **F5-TTS engine** or compatible engine for TTS inference (ensure it matches your configuration)


## Project Structure

```
book_expert/
├── data/
│   ├── raw/               # PDF input directory
│   └── <output_dir>/      # Configured work/output root
│       └── <pdf_name>/
│           ├── png/
│           ├── text/
│           ├── polished/
│           ├── tts_chunks/
│           ├── wav/
│           ├── mp3/
│           └── concat/
└── scripts/
    ├── pdf_to_png.sh
    ├── png_to_page_text.sh
    ├── polish_pdf_text.sh
    ├── concat_pages.sh
    ├── text_to_wav.sh
    ├── combine.sh
    └── ...
├── project.toml           # Central configuration file
├── README.md
```


## Configuration

**All settings are defined in `project.toml`:**

- **[paths]**: Set `input_dir` (PDFs), `output_dir` (root for output)
- **[directories]**: Subdirectory layout by stage ("polished", "chunks", "wav", etc.)
- **[processing_dir] \& [logs_dir]**: Intermediate and log file storage (use fast storage, e.g., `/tmp`)
- **[nvidia_api] \& [google_api]**:
Contains model names, endpoints, and the *variable name* that will be checked in your shell for API keys
- **[retry]**: Control retry counts/delays for external API failures
- **[f5_tts_settings]**: Controls TTS model and resources

*You MUST update any absolute paths in `project.toml` to your environment and provide your API keys as environment variables before running the scripts*.

## Setup Instructions

1. **Clone repository**

```bash
git clone <repository_url>
cd book_expert
```

2. **Install prerequisites**
    - See [Prerequisites](#prerequisites) for all CLI tools and Python packages.
    - Install `yq` via `pip` (`pip install yq`) and ensure all listed CLI tools are available.
3. **Configure your environment**
    - Edit `project.toml` and adjust all `[paths]`, `[directories]`, and API sections as needed.
    - Set required API keys for both Google Gemini and NVIDIA APIs, e.g.:

```bash
export GEMINI_API_KEY="..."
export NVIDIA_API_KEY="..."
```

4. **Make scripts executable**

```bash
chmod +x scripts/*.sh
```

5. **Prepare input directory**
    - Place all source PDFs in the directory defined by `paths.input_dir` in your `project.toml`.

## Usage

The pipeline is run **sequentially stage-by-stage**; each script operates on the outputs of the previous.

**Basic script pattern:**

```bash
./scripts/<stage>.sh
```

Example full pipeline sequence (each is a separate script):

1. `pdf_to_png.sh` – PDF → PNG images
2. `png_to_page_text.sh` – PNG → text/concepts (API via Tesseract/NVIDIA/Google)
3. `polish_pdf_text.sh` – text pages → polished, TTS-ready narration (Google Gemini)
4. `concat_pages.sh` – group polished text into longer blocks for narration chunking
5. `text_to_wav.sh` – text chunks → WAV (via F5-TTS)
6. `combine.sh` – combine WAVs to a single long WAV \& transcode to MP3

Each script will read `project.toml` and logs to its own directory.

## Pipeline Stages

| Script Name | Input Directory | Output Directory | Function |
| :-- | :-- | :-- | :-- |
| **pdf_to_png.sh** | data/raw/ | data/<pdf_name>/png/ | Converts PDF pages to PNG images |
| **png_to_page_text.sh** | data/<pdf_name>/png/ | data/<pdf_name>/text/ | OCR + API extraction: PNG to raw text and concept summaries |
| **polish_pdf_text.sh** | data/<pdf_name>/text/ | data/<pdf_name>/polished/ | Groups and polishes text for natural narration (API: Google Gemini) |
| **concat_pages.sh** | data/<pdf_name>/polished/ | data/<pdf_name>/concat/ | Concatenates polished text files into larger blocks for TTS |
| **text_to_wav.sh** | data/<pdf_name>/concat/ | data/<pdf_name>/wav/ | Converts textual chunks into WAV using F5-TTS or compatible engine |
| **combine.sh** | data/<pdf_name>/wav/ | data/<pdf_name>/mp3/ | Stages, sorts, validates, resamples, and merges WAV files — then outputs a single .wav and .mp3 for the book |

## Code Guidelines

All scripts conform to strict guidelines:

- **Declare all variables** prior to assignment
- Use **explicit `if/then/fi`** for clarity
- Always **close file/block/loops**, check error codes and **return/exit on errors**
- *Atomic operations*: Use `mv`, `flock`, and safe temporary directories to avoid parallelization issues
- *Dependency Checks*: All external tools and APIs are checked at runtime
- *Retry Logic*: Robust retry, exponential backoff for all API stages (see `project.toml`)
- *Logging*: Each stage writes its own log file; most stages print to both terminal and log
- *Use `rsync`* instead of `cp` for staging files
- Remove unused variables, unreachable code, keep code concise and self-documented
- *No hardcoded values*: All paths and settings must reference `project.toml`
- *Comments*: Extensive use of **Markdown** and descriptive comments in code

**Note:** For full reproducibility, review each script, as configuration key names and functions are subject to change between versions. Always prefer running scripts under environments where all dependencies and API keys are properly set.

---

<div style="text-align: center">⁂</div>

[^1]: combine.sh

[^2]: concat_pages.sh

[^3]: pdf_to_png.sh

[^4]: png_to_page_text.sh

[^5]: polish_pdf_text.sh

[^6]: project.toml

[^7]: README.md

[^8]: text_to_wav.sh

[^9]: README.md

