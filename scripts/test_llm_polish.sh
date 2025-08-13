#!/usr/bin/env bash
# test_llm_polish.sh
# Produce narration-ready text from OCR using llama.cpp
# Saves ONLY the model response to OUTPUT_FILE

set -euo pipefail

# Configuration
declare -r MODEL_PATH="/home/niko/Dev/book_expert/models/Qwen2.5-Omni-3B-Q8_0.gguf"
declare -r LLAMA_BINARY="/home/niko/Dev/book_expert/bin/llama-cli"
declare -r TEST_INPUT_FILE="${1:-/home/niko/Dev/book_expert/examples/Platform_Runtime_Mechanism/text/page_0001.txt}"
declare -r OUTPUT_FILE="llm_polished_test.txt"
declare -r STDERR_LOG="llm_polish_stderr.log"

# LLM parameters (deterministic)
declare -r TEMP=0.0
declare -r TOP_P=1.0
declare -r CTX_SIZE=4096
declare PROMPT=""

check_dependencies() {
    local -a missing=()
    if ! command -v "$LLAMA_BINARY" >/dev/null 2>&1; then
        missing+=("$LLAMA_BINARY")
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing dependencies: ${missing[*]}"
        echo "Please ensure llama.cpp is installed and '$LLAMA_BINARY' is executable or adjust LLAMA_BINARY."
        return 1
    fi
    if [[ ! -f "$MODEL_PATH" ]]; then
        echo "ERROR: Model not found: $MODEL_PATH"
        return 1
    fi
    return 0
}

preclean_ocr_for_narration() {
    sed \
        -e 's/\r//g' \
        -e 's/[ \t]\+$//g' \
        -e 's/^[ \t]\+//g' \
        -e 's/[ \t]\+/ /g' \
        -e '/^[ \t]*$/N;/^\n$/D' \
        -e 's/ﬁ/fi/g' \
        -e 's/ﬂ/fl/g' \
        -e 's/ﬀ/ff/g' \
        -e 's/ﬃ/ffi/g' \
        -e 's/ﬄ/ffl/g' \
        -e 's/“/"/g' \
        -e 's/”/"/g' \
        -e "s/‘/'/g" \
        -e "s/’/'/g" \
        -e 's/…/.../g' \
        -e 's/ *\([,.;:?!]\) */\1 /g' \
        -e 's/ \+/ /g'
}

polish_text_with_llm() {
    local input_text="$1"
    local composed_prompt
    composed_prompt="${PROMPT} ${input_text}"

    declare text
    text=$("$LLAMA_BINARY" \
        --model "$MODEL_PATH" \
        --ctx-size "$CTX_SIZE" \
        --temp "$TEMP" \
        --top-p "$TOP_P" \
        -ngl 37 \
        -sys "You are an expert technical editor" \
        -no-cnv \
        --simple-io \
        -mli \
        -st \
        --no-perf \
        -fa \
        -b 256 -p "$composed_prompt")

    echo "$text" >stdout

    return 0
}

main() {
    echo "=== Narration-ready OCR Cleanup ==="
    echo "Model: $MODEL_PATH"
    echo "Input: $TEST_INPUT_FILE"
    echo "Output: $OUTPUT_FILE"
    # Narration-oriented prompt (no acronym assumptions)

    PROMPT="You are an expert text editor preparing OCR text for audiobook narration.
Correct only obvious OCR artifacts and improve readability without changing meaning.
Make conservative fixes:
- Repair broken hyphenation at line breaks
- Normalize punctuation and spacing (quotes, dashes, ellipses; single space after sentence-ending punctuation).
- Fix common OCR ligatures 
- Preserve technical terms; do NOT invent or expand acronyms unless already present.
- Keep paragraph structure sensible; merge broken line-wrapped lines within paragraphs.
- Remove duplicated lines/blocks caused by OCR glitches.
- Output only the corrected text; no commentary.
Correct the following text:
"

    echo "Reading input text..."
    local raw_text
    raw_text="$(<"$TEST_INPUT_FILE")"
    if [[ -z "$raw_text" ]]; then
        echo "ERROR: Input file is empty"
        exit 1
    fi

    echo "Pre-cleaning OCR artifacts..."
    local input_text
    input_text="$(printf '%s' "$raw_text" | preclean_ocr_for_narration)"

    echo "Processing with LLM..."
    if ! polish_text_with_llm "$input_text"; then
        echo "ERROR: LLM processing failed. See $STDERR_LOG"
        exit 1
    fi

    echo "Output saved to: $OUTPUT_FILE"
}

main "$@"
