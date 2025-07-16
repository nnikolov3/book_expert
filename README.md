# Document Processing Pipeline

Note: The `examples` directory contains examples of converting pdf to an audio book. I do not own the rights of the pdf. The pdfs are used for reference only. This is entirely meant for educational purposes only.

This repository contains a suite of Bash scripts designed to automate the conversion of PDF documents into polished text and then into audio (WAV) files. The pipeline is modular, allowing for easy extension and customization of each processing stage.

## Table of Contents

1.  [Prerequisites](https://www.google.com/search?q=%23prerequisites)
2.  [Project Structure](https://www.google.com/search?q=%23project-structure)
3.  [Configuration](https://www.google.com/search?q=%23configuration)
4.  [Setup Instructions](https://www.google.com/search?q=%23setup-instructions)
5.  [Usage](https://www.google.com/search?q=%23usage)
6.  [Pipeline Stages](https://www.google.com/search?q=%23pipeline-stages)
7.  [Code Guidelines](https://www.google.com/search?q=%23code-guidelines)

## 1\. Prerequisites

Before you begin, ensure you have the following installed on your system:

  * **Bash**: The scripts are written in Bash.
  * **ImageMagick**: Required for `pdf_to_png.sh` to convert PDFs to PNG images.
    ```bash
    sudo apt-get update
    sudo apt-get install imagemagick
    ```
  * **Ghostscript**: Often comes with ImageMagick, but ensure it's available for PDF processing.
    ```bash
    sudo apt-get install ghostscript
    ```
  * **Tesseract OCR**: Required for `png_to_page_text.sh` to extract text from PNG images.
    ```bash
    sudo apt-get install tesseract-ocr
    ```
  * **`toml-cli`**: Used for parsing the `project.toml` configuration file.
    ```bash
    pip install toml-cli
    ```
  * **`f5-tts` (or similar TTS engine)**: The `text_chunks_to_wav.sh` script is designed to interface with an F5-TTS inference engine. You will need to set up and run this engine separately, ensuring its API is accessible as configured in `project.toml`.
  * **Google Gemini API Key**: Required for `png_to_page_text.sh` and `polish_pdf_text.sh` for text extraction and polishing. This key should be set as an environment variable (e.g., `GEMINI_API_KEY`).
  * **`rsync`**: Used for efficient file synchronization and copying.
    ```bash
    sudo apt-get install rsync
    ```
  * **`shellcheck`**: Recommended for linting the Bash scripts.
    ```bash
    sudo apt-get install shellcheck
    ```

## 2\. Project Structure

The core project structure is as follows:

```
book_expert/
├── data/
│   ├── raw/                # Input directory for raw PDF files
│   └── (output_dir)/       # Main output directory (configured in project.toml)
│       ├── {pdf_name}/
│           ├── png/            # PNG images generated from PDF pages
│           ├── text/           # Raw text extracted from PNGs
│           ├── polished/       # Polished text files
│           ├── tts_chunks/     # Text chunks ready for TTS
│           ├── wav/            # Final WAV audio files
│           └── logs/           # Project-specific logs
├── scripts/
│   ├── combine.sh
│   ├── pdf_to_png.sh
│   ├── png_to_page_text.sh
│   ├── polish_pdf_text.sh
│   ├── text_chunks_to_wav.sh
│   └── text_page_to_text_chunks.sh
├── project.toml            # Main configuration file
└── README.md
```

## 3\. Configuration

The pipeline's behavior is controlled by the `project.toml` file. This file defines paths, API settings, retry mechanisms, and other crucial parameters.

**`project.toml` Example Snippets and Explanation:**

```toml
# ================================================================================================
# PROJECT CONFIGURATION FOR DOCUMENT PROCESSING PIPELINE
# Design: Niko Nikolov
# Code: Various LLMs
# ================================================================================================

[project]
name = "book_expert"
version = "0.0.0"

# ================================================================================================
# [paths]
# Defines the directory structure for the pipeline.
# ================================================================================================
[paths]
# Directory for raw PDF inputs
input_dir = "/home/niko/Dev/book_expert/data/raw"
output_dir = "/home/niko/Dev/book_expert/data"

[directories]
polished_dir= "polished"
chunks= "chunks"
tts_chunks= "tts_chunks"
wav = "wav"
mp3 = "mp3"

# ================================================================================================
# [processing_dir]
# Processing temp director
# ================================================================================================
[processing_dir]
pdf_to_png = "/tmp/pdf_to_png"
png_to_text= "/tmp/png_to_text"
polish_text = "/tmp/polished"
text_to_chunks = "/tmp/text_to_chunks"
chunks_to_wav = "/tmp/chunks_to_wav"
combine_chunks = "/tmp/combine_chunks"

# ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

[logs_dir]
pdf_to_png = "/tmp/logs/pdf_to_png"
png_to_text= "/tmp/logs/png_to_text"
polish_text = "/tmp/logs/polished"
text_to_chunks = "/tmp/logs/text_to_chunks"
chunks_to_wav = "/tmp/logs/chunks_to_wav"
combine_chunks = "/tmp/logs/combine_chunks"

# ===============================================================================================
# [nvidia_api]
# NVIDIA API settings for text extraction from PNGs.
# ===============================================================================================
[nvidia_api]
url = "http://localhost:5000/v1/infer" # Example URL, adjust to your NVIDIA API endpoint
api_key_variable = "NVIDIA_API_KEY"
max_retries = 5
retry_delay_seconds = 10

# ===============================================================================================
# [google_api]
# Google Gemini API settings for final narration polishing.
# ===============================================================================================
[google_api]
polish_model = "gemini-2.5-flash-preview-05-20"
url = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
api_key_variable = "GEMINI_API_KEY"
max_retries = 5
retry_delay_seconds = 30


# ===============================================================================================
# [f5_tts_settings]
# Settings for the F5-TTS engine used in Stage 4 (Chunks to WAV).
# ===============================================================================================
[f5_tts_settings]
model = "E2TTS_Base"
workers = 2
timeout_duration = 300

# ===============================================================================================
# [retry]
# Settings for the failure retry mechanism for API calls and TTS conversion.
# ===============================================================================================
[retry]
max_retries = 5
retry_delay_seconds = 60
```

**Key Configuration Points:**

  * **`[paths]`**: Define `input_dir` (where your raw PDFs are placed) and `output_dir` (the root for all processed outputs).
  * **`[directories]`**: Specifies the names of subdirectories created within each PDF's output folder.
  * **`[processing_dir]`**: Defines temporary directories used by each script for intermediate processing. Ensure these paths are accessible and have sufficient disk space.
  * **`[logs_dir]`**: Specifies directories for logs generated by each script.
  * **`[nvidia_api]`**: Configure the URL and API key variable for your NVIDIA text extraction service.
  * **`[google_api]`**: Configure the URL, model, and API key variable for the Google Gemini API, used for text polishing.
  * **`[f5_tts_settings]`**: Set the TTS model, number of parallel workers, and timeout for the F5-TTS engine.
  * **`[retry]`**: Global retry settings for failed operations.

**Important:**

  * Update `input_dir` and `output_dir` in `project.toml` to reflect your local file system.
  * Ensure the API key environment variables (e.g., `NVIDIA_API_KEY`, `GEMINI_API_KEY`) are set in your shell environment before running the scripts.

## 4\. Setup Instructions

1.  **Clone the Repository (if applicable):**

    ```bash
    git clone <repository_url>
    cd book_expert
    ```

2.  **Install Prerequisites:**
    Follow the instructions in the [Prerequisites](https://www.google.com/search?q=%23prerequisites) section to install all necessary software and libraries.

3.  **Configure `project.toml`:**
    Open `project.toml` and adjust the `input_dir`, `output_dir`, and API endpoints/keys according to your environment.

      * **Example for `input_dir` and `output_dir`:**
        ```toml
        [paths]
        input_dir = "/path/to/your/raw_pdfs"
        output_dir = "/path/to/your/processed_data"
        ```
      * **Set API Keys:**
        ```bash
        export GEMINI_API_KEY="YOUR_GEMINI_API_KEY"
        export NVIDIA_API_KEY="YOUR_NVIDIA_API_KEY" # If applicable
        ```
        It is recommended to add these `export` commands to your `~/.bashrc` or `~/.zshrc` file to set them automatically on shell startup.

4.  **Make Scripts Executable:**
    Navigate to the `scripts/` directory and make all `.sh` files executable:

    ```bash
    chmod +x scripts/*.sh
    ```

5.  **Prepare Input Directory:**
    Place your PDF files into the directory specified by `input_dir` in `project.toml`.

## 5\. Usage

The pipeline is designed to be run sequentially, with each script performing a specific stage. You can run individual scripts or orchestrate them with a master script (not provided, but `combine.sh` gives an idea of orchestration).

**General Execution Pattern:**

```bash
./scripts/<script_name>.sh [optional_arguments]
```

Each script typically reads its configuration from `project.toml`.

## 6\. Pipeline Stages

Here's a brief overview of each script's role in the pipeline:

  * **`pdf_to_png.sh`**:

      * **Input**: PDF files from `input_dir`.
      * **Output**: Converts each page of a PDF into a high-resolution PNG image, stored in `{output_dir}/{pdf_name}/png/`.
      * **Purpose**: Prepares visual data for OCR.

  * **`png_to_page_text.sh`**:

      * **Input**: PNG images from `{output_dir}/{pdf_name}/png/`.
      * **Output**: Extracts text from each PNG image using OCR (Tesseract) and potentially refines it with an NVIDIA API, saving raw text files to `{output_dir}/{pdf_name}/text/`.
      * **Purpose**: Converts visual page data into raw textual content.

  * **`polish_pdf_text.sh`**:

      * **Input**: Raw text files from `{output_dir}/{pdf_name}/text/`.
      * **Output**: Combines sequential text pages (e.g., page 1 & 2, page 3 & 4) and polishes the text using the Google Gemini API, saving results to `{output_dir}/{pdf_name}/polished/`. Handles odd numbers of pages by processing the last page alone.
      * **Purpose**: Improves text quality and readability, preparing it for chunking.

  * **`text_page_to_text_chunks.sh`**:

      * **Input**: Polished text files from `{output_dir}/{pdf_name}/polished/`.
      * **Output**: Splits the polished text into smaller, paragraph-based chunks, saving them to `{output_dir}/{pdf_name}/tts_chunks/`.
      * **Purpose**: Creates appropriately sized text segments for Text-to-Speech conversion.

  * **`text_chunks_to_wav.sh`**:

      * **Input**: Text chunks from `{output_dir}/{pdf_name}/tts_chunks/`.
      * **Output**: Converts each text chunk into an individual WAV audio file using the F5-TTS engine, saving them to `{output_dir}/{pdf_name}/wav/`. Supports parallel processing and GPU management.
      * **Purpose**: Generates audio versions of the document content.

  * **`combine.sh`**:

      * **Input**: WAV files from `{output_dir}/{pdf_name}/wav/`.
      * **Output**: Combines the individual WAV files for a given PDF project into a single, cohesive audio file (e.g., an MP3).
      * **Purpose**: Creates a complete audio rendition of the document.

## 7\. Code Guidelines

The scripts adhere to a set of internal code guidelines to ensure consistency, readability, and robustness:

  * Declare variables before assignment.
  * Use explicit `if/then/fi` blocks.
  * Employ atomic file operations (`mv`, `flock`) for race condition prevention.
  * Avoid mixing API calls within a single function/block.
  * Lint with `shellcheck`.
  * Use `grep -q` for silent checks.
  * Check for unbound variables with `set -u`.
  * Clean up unused variables and maintain detailed comments.
  * Avoid unreachable code or redundant commands.
  * Keep code concise, clear, and self-documented.
  * Avoid `cat` where `cmd < file` is more appropriate.
  * Use `declare` for global variables and `local` for function-scoped variables.
  * Initialize all variables.
  * Use `rsync` instead of `cp` for directory synchronization.
  * Comments should be maintained and updated, using Markdown within comment blocks.

-----
