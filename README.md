# Document-to-Audiobook Pipeline

A restart-safe, strictly-linted Bash tool-chain that turns any PDF into a polished, single-file MP3.

Status

- Fully exercised on **Fedora 42** (stock repos + RPM Fusion)
- **Untested on Ubuntu** – behaviour there is unknown
- TTS layer powered by the project-specific fork: `https://github.com/nnikolov3/book_expert_f5-tts`

--------------------------------------------------------------------------------
1  What the Repository Does
--------------------------------------------------------------------------------
1. PDF → high-DPI PNG pages (Ghostscript)
2. PNG → OCR text (Tesseract)
3. OCR text → LLM-enhanced narration text (Gemini)
4. 3-page groups → unified prose (Cerebras)
5. Unified groups → chapter-sized final narration text (Cerebras)
6. Final text → WAV chunks (F5-TTS fork)
7. WAV chunks → 48 kHz mono WAV → MP3 (FFmpeg)

All scripts obey the rules in `CODE_GUIDELINES_LLM.md` (ShellCheck clean, no hidden failures, atomic file ops, variables declared before use, etc.).

--------------------------------------------------------------------------------
2  Repository Layout (paths can be changed in `project.toml`)
--------------------------------------------------------------------------------
```
book_expert/
├── data/
│   ├── raw/                 # Source PDFs (paths.input_dir)
│   └── <pdf_name>/          # One dir per document
│       ├── png/             # Per-page images
│       ├── text/            # OCR + Gemini text
│       ├── unified_text/    # 3-page groups
│       ├── final_text/      # Chapter-sized narration text
│       ├── wav/             # F5-TTS chunks
│       ├── resampled/       # 48 kHz mono WAVs
│       └── mp3/             # Finished audiobook
├── scripts/                 # Pipeline stages
├── helpers/                 # Logging, config utilities
├── project.toml             # ★ all directory & pipeline configuration ★
├── CODE_GUIDELINES_LLM.md
└── README.md
```

The **exact directory names and locations** are not hard-coded; they come from the `[paths]`, `[directories]`, `[processing_dir]` and `[logs_dir]` blocks inside **`project.toml`**. Edit those keys to redirect input, output or temp folders to any location on your system.

--------------------------------------------------------------------------------
3  Quick-Start (Fedora 42)
--------------------------------------------------------------------------------
1. System packages

```bash
sudo dnf install \
  ghostscript tesseract tesseract-langpack-eng \
  poppler-utils ImageMagick jq yq rsync ffmpeg \
  shellcheck nproc coreutils awk grep curl flock
```

2. F5-TTS fork

```bash
git clone https://github.com/nnikolov3/book_expert_f5-tts.git
cd book_expert_f5-tts
python -m venv .venv && source .venv/bin/activate
pip install -e .
```

3. Clone this repo \& make scripts executable

```bash
git clone https://github.com/<your-org>/book_expert.git
cd book_expert
chmod +x scripts/*.sh helpers/*.sh
```

4. Supply any API keys you’ll use

```bash
export GEMINI_API_KEY="sk-…"      # Google Gemini
export CEREBRAS_API_KEY="cb-…"     # Cerebras inference endpoint
# export NVIDIA_API_KEY="na-…"     # Optional
```

5. Open **`project.toml`** and adjust:
    - `[paths]` / `[directories]` / `[processing_dir]` / `[logs_dir]` – folder layout
    - `[settings]` – DPI, `force`, worker counts
    - `[google_api]` \& `[cerebras_api]` – model names, temps, tokens
    - `[f5_tts_settings]` – TTS model, worker threads
    - `[prompts.*]` – full system/user prompts used by each LLM call

--------------------------------------------------------------------------------
4  LLM Integration at a Glance
--------------------------------------------------------------------------------
Stage → Script → Default model key (in `project.toml`)

```
OCR enrichment          generate_page_text.sh   google_api.GEMINI_MODELS[^0]
3-page unification      unify_page_text.sh      cerebras_api.unify_model
Final polishing         finalize_page_text.sh   cerebras_api.final_model
```

Everything—model, temperature, tokens, retries, **and the complete prompt text**—is configured through `project.toml`; no Bash edits required.

--------------------------------------------------------------------------------
5  Running the Pipeline
--------------------------------------------------------------------------------
```bash
./scripts/generate_pngs.sh          # PDF → PNG
./scripts/generate_page_text.sh     # PNG → OCR + Gemini
./scripts/unify_page_text.sh        # page groups → unified text
./scripts/finalize_page_text.sh     # unified groups → final narration
./scripts/merge_text.sh             # concat → complete.txt
./scripts/generate_wav.sh           # text → WAV chunks (F5-TTS)
./scripts/generate_mp3.sh           # WAVs → single MP3
```

Each script

- reads `project.toml` for config and directory paths
- logs to `data/logs/<stage>/` (also configurable)
- is idempotent—rerun safely; set `settings.force = 1` to overwrite

--------------------------------------------------------------------------------
6  Typical Workflow
--------------------------------------------------------------------------------
1. Drop PDFs into the folder pointed to by `paths.input_dir` (default `data/raw/`).
2. Execute the seven scripts in order (can be parallelised).
3. Find your audiobook at `<output_dir>/<pdf_name>/mp3/<pdf_name>.mp3`.

--------------------------------------------------------------------------------
7  Configuration Cheat-Sheet (`project.toml`)
--------------------------------------------------------------------------------
Most-touched blocks:

- `[paths]`, `[directories]`, `[processing_dir]`, `[logs_dir]` – **all folder locations**
- `[settings]` – DPI, worker counts, force rebuild flag
- `[google_api]`, `[cerebras_api]` – model, temp, tokens, key var names
- `[prompts.*]` – editable multi-paragraph prompts for every LLM stage
- `[f5_tts_settings]` – TTS model name and worker threads
- `[retry]` – global max-retries \& back-off seconds

Because every script queries these keys at runtime, you can rearrange directories, switch models, or rewrite prompts without touching the Bash code.

--------------------------------------------------------------------------------
8  Troubleshooting
--------------------------------------------------------------------------------
- Missing binary → install the package shown in the error.
- Missing API key → script prints which env-var is absent.
- HTTP 429 from Cerebras → script sleeps `retry.retry_delay_seconds` then retries.
- Partial runs/crashes → rerun the same script; completed outputs are skipped unless `force = 1`.

--------------------------------------------------------------------------------
9  Extending
--------------------------------------------------------------------------------
- Swap in any other TTS engine—edit `generate_wav.sh` or write a small wrapper that mimics `f5-tts_infer-cli`.
- Change grouping ratios—edit the constants at the top of `unify_page_text.sh` (default 3 pages) and `finalize_page_text.sh` (default 2 groups).
- Add additional cleaning rules—extend `helpers/clean_text_helper.sh`.

--------------------------------------------------------------------------------
10  Contributing
--------------------------------------------------------------------------------
1. All Bash files must pass `shellcheck -x`.
2. Declare variables before use; globals contain the substring `GLOBAL`.
3. No redirection to `/dev/null`; capture and log every error.
4. PR commit messages should be prefixed by the stage you touched (e.g., `generate_wav:` …).

