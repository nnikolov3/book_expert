#!/usr/bin/env bash
set -euo pipefail

# Minimal PDF -> PNG with fast blank detection per worker

# ========= Readonly helpers =========
declare -r CONFIG_GET_HELPER_GLOBAL="helpers/get_config_helper.sh"
declare -r LOGGER_HELPER_GLOBAL="helpers/logging_utils_helper.sh"

# ========= Globals (from TOML) =========
declare INPUT_DIR_GLOBAL=""
declare OUTPUT_DIR_GLOBAL=""
declare DPI_GLOBAL=""
declare LOG_FILE_GLOBAL=""
declare LOG_DIR_GLOBAL=""
declare NUM_WORKERS_GLOBAL=0
declare SKIP_BLANK_PAGES_GLOBAL=""
declare BLANK_FAST_THRESHOLD_GLOBAL="" # ratio for non-white (e.g., 0.005)
declare BLANK_FAST_FUZZ_GLOBAL=""      # fuzz percent for near-white mask (e.g., 5)

# Path to the Go blank detection binary
declare -r BLANK_DETECTOR_GO_BIN="./detect_blank_go"

# ========= Runtime state =========
declare -a WORKER_FIFO_PATHS_GLOBAL=()
declare -a WORKER_PIDS_GLOBAL=()
declare -A BLANK_PAGE_HASH_CACHE_GLOBAL=()

# ========= Logging shims (populated after sourcing) =========
function log_info() { :; }
function log_warn() { :; }
function log_error() { :; }
function log_success() { :; }
function print_line() { :; }

# ========= Basics =========
function require_commands() {
    local -a deps=()
    local dep=""
    local have=""

    # Add 'go' to the list of required commands
    deps=("ghostscript" "pdfinfo" "mkfifo" "getconf" "identify" "convert" "find" "sort" "awk" "sed" "tr" "nproc" "go")

    for dep in "${deps[@]}"; do
        have="$(command -v "$dep" 2>&1 || true)"
        if [[ -z "$have" ]]; then
            echo "ERROR: Required command not found: $dep" >&2
            exit 1
        fi
    done
}

function detect_logical_cpus() {
    local nproc_result=""
    local getconf_result=""
    local cpus=""

    nproc_result="$(nproc --all 2>&1 || true)"
    if [[ -n "$nproc_result" ]] && [[ "$nproc_result" =~ ^[0-9]+$ ]]; then
        cpus="$nproc_result"
    else
        getconf_result="$(getconf _NPROCESSORS_ONLN 2>&1 || true)"
        if [[ -n "$getconf_result" ]] && [[ "$getconf_result" =~ ^[0-9]+$ ]]; then
            cpus="$getconf_result"
        fi
    fi

    if [[ -z "$cpus" ]] || ! [[ "$cpus" =~ ^[0-9]+$ ]] || [[ "$cpus" -lt 1 ]]; then
        echo "ERROR: Failed to detect logical CPU count" >&2
        exit 1
    fi

    printf '%s\n' "$cpus"
}

function count_files_in_dir() {
    local dir=""
    local pattern=""
    local count_result=""

    dir="$1"
    pattern="$2"

    if [[ -z "$dir" || -z "$pattern" ]]; then
        printf '%s\n' "0"
        return 1
    fi

    if [[ -d "$dir" ]]; then
        count_result="$(find "$dir" -maxdepth 1 -type f -name "$pattern" | wc -l | tr -d ' ')"
        printf '%s\n' "$count_result"
    else
        printf '%s\n' "0"
    fi
}

# ========= Fast blank detection =========
# Method A (primary): uses Go binary for near-white mask mean -> non_white_ratio = 1 - mean
# Blank if non_white_ratio <= BLANK_FAST_THRESHOLD_GLOBAL
function is_near_white_fast() {
    local png_path=""
    # Removed go_out as its output is handled by stderr redirection or simply ignored
    local go_exit=""
    local thr=""

    png_path="$1"
    thr="$BLANK_FAST_THRESHOLD_GLOBAL"

    # Call the pre-compiled Go binary
    # The Go binary returns exit code 0 for blank, 1 for not blank, 2 for error
    "$BLANK_DETECTOR_GO_BIN" "$png_path" "$BLANK_FAST_FUZZ_GLOBAL" "$thr" >/dev/null 2>&1 # Redirect stdout/stderr to suppress output
    go_exit="$?"

    if [[ "$go_exit" -eq 0 ]]; then # Go program returned 0, meaning it's blank
        return 0
    elif [[ "$go_exit" -eq 1 ]]; then # Go program returned 1, meaning it's not blank
        return 1
    else # Go program returned 2, meaning an internal error occurred
        log_error "Go blank detection failed for $png_path. Exit code: $go_exit"
        return 2 # Indicate an internal error, same as original logic
    fi
}

# Optional fallback: histogram-based exact white count (slower but still lean)
function is_near_white_hist() {
    local png_path=""
    local convert_out=""
    local conv_exit=""
    local white_count=""
    local total_pixels_out=""
    local total_pixels=""
    local non_white_ratio=""
    local thr=""

    png_path="$1"
    thr="$BLANK_FAST_THRESHOLD_GLOBAL"

    convert_out="$(convert "$png_path" -define histogram:unique-colors=true -format %c histogram:info:- 2>&1 || true)"
    conv_exit="$?"
    if [[ "$conv_exit" -ne 0 || -z "$convert_out" ]]; then
        return 2
    fi

    white_count="$(printf '%s\n' "$convert_out" | sed -n 's/^ *\([0-9]\+\):.*white.*$/\1/p' | head -1)"
    white_count="${white_count:-0}"

    total_pixels_out="$(convert "$png_path" -format "%[fx:w*h]" info: 2>&1 || true)"
    if [[ -z "$total_pixels_out" ]] || ! [[ "$total_pixels_out" =~ ^[0-9]+$ ]] || [[ "$total_pixels_out" -eq 0 ]]; then
        return 2
    fi
    total_pixels="$total_pixels_out"

    non_white_ratio="$(awk -v w="$white_count" -v t="$total_pixels" 'BEGIN { printf("%.6f", (t - w)/t) }')"

    if awk -v nwr="$non_white_ratio" -v t="$thr" 'BEGIN { exit (nwr <= t ? 0 : 1) }'; then
        return 0
    fi
    return 1
}

function get_image_hash() {
    local png_path=""
    local out=""

    png_path="$1"
    out="$(identify -format "%#" "$png_path" 2>&1 || true)"
    if [[ -n "$out" ]]; then
        printf '%s\n' "$out"
        return 0
    fi

    out="$(identify -format "%wx%h_%B" "$png_path" 2>&1 || echo "unknown")"
    printf 'fallback_%s\n' "$out"
}

function is_blank_page_fast() {
    local png_path=""
    png_path="$1"

    if is_near_white_fast "$png_path"; then
        return 0
    fi

    # Uncomment if wanting the histogram fallback for borderline pages
    # if is_near_white_hist "$png_path"; then
    #     return 0
    # fi

    return 1
}

function is_blank_page_cached_fast() {
    local png_path=""
    local img_hash=""

    png_path="$1"
    img_hash="$(get_image_hash "$png_path")"

    if [[ -n "${BLANK_PAGE_HASH_CACHE_GLOBAL[$img_hash]:-}" ]]; then
        if [[ "${BLANK_PAGE_HASH_CACHE_GLOBAL[$img_hash]}" == "blank" ]]; then
            return 0
        fi
        return 1
    fi

    if is_blank_page_fast "$png_path"; then
        BLANK_PAGE_HASH_CACHE_GLOBAL[$img_hash]="blank"
        return 0
    fi

    BLANK_PAGE_HASH_CACHE_GLOBAL[$img_hash]="content"
    return 1
}

# ========= File ops =========
function remove_file_safely() {
    local file_path=""
    local rm_out=""
    local rm_exit=1

    file_path="$1"

    if [[ -z "$file_path" ]]; then
        echo "ERROR: remove_file_safely called with empty path" >&2
        return 1
    fi
    if [[ ! -f "$file_path" ]]; then
        echo "ERROR: File not found for removal: $file_path" >&2
        return 1
    fi

    rm_out="$(rm "$file_path" 2>&1 || true)"
    rm_exit="$?"
    if [[ "$rm_exit" -ne 0 ]]; then
        echo "ERROR: Failed to remove file: $file_path: $rm_out" >&2
        return "$rm_exit"
    fi
    return 0
}

# ========= Rendering =========

function render_page() {
    local pdf_path=""
    local dpi=""
    local page_index=""
    local out_png=""
    local gs_out=""
    local gs_exit=""

    pdf_path="$1"
    dpi="$2"
    page_index="$3"
    out_png="$4"

    gs_out="$(
        ghostscript \
            -dNOPAUSE \
            -dBATCH \
            -sDEVICE=png16m \
            -r"$dpi" \
            -dFirstPage="$page_index" \
            -dLastPage="$page_index" \
            -o "$out_png" \
            -dTextAlphaBits=4 \
            -dGraphicsAlphaBits=4 \
            -dDownScaleFactor=1 \
            -dPDFFitPage \
            "$pdf_path" 2>&1 || true
    )"
    gs_exit="$?"

    if [[ "$gs_exit" -ne 0 ]]; then
        printf '%s\n' "Ghostscript failed for page $page_index: $gs_out" >&2
        return "$gs_exit"
    fi
    if [[ ! -f "$out_png" ]]; then
        printf '%s\n' "Missing output file after Ghostscript for page $page_index: $out_png" >&2
        return 1
    fi
    return 0
}

# ========= Worker model =========
function worker_loop() {
    local fifo_path=""
    local pdf_path=""
    local dpi=""
    local out_dir=""
    local line=""
    local page_idx=""
    local page_padded=""
    local out_png=""
    local render_exit=""
    local exit_any=0
    local rm_exit=1

    fifo_path="$1"
    pdf_path="$2"
    dpi="$3"
    out_dir="$4"

    while IFS= read -r line; do
        if [[ "$line" == "STOP" ]]; then
            break
        fi

        page_idx="$line"
        page_padded="$(printf "%04d" "$page_idx")"
        out_png="${out_dir}/page_${page_padded}.png"

        render_page "$pdf_path" "$dpi" "$page_idx" "$out_png"
        render_exit="$?"
        if [[ "$render_exit" -ne 0 ]]; then
            exit_any=1
            continue
        fi

        if [[ "$SKIP_BLANK_PAGES_GLOBAL" == "true" ]]; then
            if is_blank_page_cached_fast "$out_png"; then
                remove_file_safely "$out_png"
                rm_exit="$?"
                if [[ "$rm_exit" -eq 0 ]]; then
                    log_info "Removed blank (worker-fast): $(basename "$out_png")"
                else
                    log_warn "Failed to remove blank (worker-fast): $(basename "$out_png")"
                fi
            fi
        fi
    done <"$fifo_path"

    return "$exit_any"
}

function create_worker_fifos() {
    local workers=""
    local i=0
    local fifo_path=""
    local mkfifo_exit=""

    workers="$1"
    WORKER_FIFO_PATHS_GLOBAL=()

    for i in $(seq 1 "$workers"); do
        fifo_path="$(mktemp -u).fifo.$$.$i"
        if [[ -e "$fifo_path" ]]; then
            echo "ERROR: FIFO already exists: $fifo_path" >&2
            exit 1
        fi
        mkfifo "$fifo_path"
        mkfifo_exit="$?"
        if [[ "$mkfifo_exit" -ne 0 ]]; then
            echo "ERROR: Failed to create FIFO: $fifo_path" >&2
            exit 1
        fi
        WORKER_FIFO_PATHS_GLOBAL+=("$fifo_path")
    done
}

function start_workers() {
    local workers=""
    local i=0
    local fifo=""
    local pid=""
    local pdf_path=""
    local dpi=""
    local out_dir=""

    workers="$1"
    pdf_path="$2"
    dpi="$3"
    out_dir="$4"

    WORKER_PIDS_GLOBAL=()

    for i in $(seq 1 "$workers"); do
        fifo="${WORKER_FIFO_PATHS_GLOBAL[$((i - 1))]}"
        worker_loop "$fifo" "$pdf_path" "$dpi" "$out_dir" &
        pid="$!"
        WORKER_PIDS_GLOBAL+=("$pid")
    done
}

function stop_workers() {
    local workers=""
    local i=0
    local fifo=""
    local pid=""
    local fail_count=0
    local wait_exit=""

    workers="${#WORKER_FIFO_PATHS_GLOBAL[@]}"

    for i in $(seq 1 "$workers"); do
        fifo="${WORKER_FIFO_PATHS_GLOBAL[$((i - 1))]}"
        printf '%s\n' "STOP" >"$fifo"
    done

    for pid in "${WORKER_PIDS_GLOBAL[@]}"; do
        wait "$pid"
        wait_exit="$?"
        if [[ "$wait_exit" -ne 0 ]]; then
            fail_count=$((fail_count + 1))
        fi
    done

    for fifo in "${WORKER_FIFO_PATHS_GLOBAL[@]}"; do
        if [[ -p "$fifo" ]]; then
            rm -f "$fifo"
        fi
    done

    if [[ "$fail_count" -ne 0 ]]; then
        echo "ERROR: $fail_count worker(s) reported errors" >&2
        return 1
    fi
    return 0
}

function schedule_pages_round_robin() {
    local total_pages=""
    local workers=""
    local page=0
    local idx=0
    local fifo=""

    total_pages="$1"
    workers="$2"

    for page in $(seq 1 "$total_pages"); do
        idx=$(((page - 1) % workers))
        fifo="${WORKER_FIFO_PATHS_GLOBAL[$idx]}"
        printf '%s\n' "$page" >"$fifo"
    done
}

# ========= Core pipeline =========
function process_one_pdf_parallel() {
    local pdf_path=""
    local pdf_name=""
    local out_dir=""
    local dpi=""
    local workers=""
    local info_out=""
    local pages=""
    local mkdir_exit=""
    local stop_exit=""
    local generated_count=""

    pdf_path="$1"
    dpi="$2"
    workers="$3"

    pdf_name="$(basename "$pdf_path" .pdf)"
    out_dir="${OUTPUT_DIR_GLOBAL}/${pdf_name}/png"

    log_info "Output directory: ${out_dir}"

    mkdir -p "$out_dir"
    mkdir_exit="$?"
    if [[ "$mkdir_exit" -ne 0 ]]; then
        log_error "Failed to create output directory: ${out_dir}"
        return 1
    fi

    info_out="$(pdfinfo "$pdf_path" 2>&1 || true)"
    if [[ -z "$info_out" ]]; then
        log_error "Failed to get PDF info for ${pdf_path}"
        return 1
    fi

    pages="$(printf '%s\n' "$info_out" | awk '/^Pages:/ {print $2}')"
    if [[ -z "$pages" ]] || ! [[ "$pages" =~ ^[0-9]+$ ]] || [[ "$pages" -lt 1 ]]; then
        log_error "Invalid page count for ${pdf_path}"
        return 1
    fi

    log_info "Converting ${pages} pages with ${workers} workers"

    create_worker_fifos "$workers"
    start_workers "$workers" "$pdf_path" "$dpi" "$out_dir"
    schedule_pages_round_robin "$pages" "$workers"
    stop_workers
    stop_exit="$?"

    if [[ "$stop_exit" -ne 0 ]]; then
        log_error "Workers failed for ${pdf_name}"
        return 1
    fi

    generated_count="$(count_files_in_dir "$out_dir" "*.png")"
    log_success "Completed ${pdf_name}: ${generated_count} final PNG files"
    return 0
}

# ========= Main =========
function main() {
    local start_time=""
    local cfg=""
    local cfg_exit=""
    local -a pdf_files=()
    local array_len=0
    local pdf=""
    local processed=0
    local failed=0
    local total=0
    local cpus=""
    local workers_cfg=""
    local process_exit=""

    require_commands

    # Check if the Go binary exists, if not, try to build it
    if [[ ! -f "$BLANK_DETECTOR_GO_BIN" ]]; then
        log_info "Go blank detection binary not found. Attempting to build..."
        if ! go build -o "$BLANK_DETECTOR_GO_BIN" "detect_blank_go.go"; then
            log_error "Failed to build Go blank detection binary. Ensure 'detect_blank_go.go' is in the current directory and Go is installed."
            exit 1
        fi
        log_success "Successfully built Go blank detection binary: $BLANK_DETECTOR_GO_BIN"
    fi

    start_time="$(date +%c)"

    cfg="$("$CONFIG_GET_HELPER_GLOBAL" "logs_dir.pdf_to_png" 2>&1 || true)"
    cfg_exit="$?"
    if [[ "$cfg_exit" -ne 0 || -z "$cfg" ]]; then
        echo "ERROR: Failed to load logs_dir.pdf_to_png" >&2
        exit 1
    fi
    LOG_DIR_GLOBAL="$cfg"

    mkdir -p "$LOG_DIR_GLOBAL"
    LOG_FILE_GLOBAL="${LOG_DIR_GLOBAL}/log_$(date +'%Y%m%d_%H%M%S').log"

    # shellcheck disable=SC1090
    source "$LOGGER_HELPER_GLOBAL"
    touch "$LOG_FILE_GLOBAL"

    log_info "PDF->PNG conversion started: ${start_time}"
    print_line

    cfg="$("$CONFIG_GET_HELPER_GLOBAL" "paths.output_dir" 2>&1 || true)"
    cfg_exit="$?"
    if [[ "$cfg_exit" -ne 0 || -z "$cfg" ]]; then
        log_error "Failed to load paths.output_dir"
        exit 1
    fi
    OUTPUT_DIR_GLOBAL="$cfg"

    cfg="$("$CONFIG_GET_HELPER_GLOBAL" "paths.input_dir" 2>&1 || true)"
    cfg_exit="$?"
    if [[ "$cfg_exit" -ne 0 || -z "$cfg" ]]; then
        log_error "Failed to load paths.input_dir"
        exit 1
    fi
    INPUT_DIR_GLOBAL="$cfg"

    cfg="$("$CONFIG_GET_HELPER_GLOBAL" "settings.dpi" 2>&1 || true)"
    cfg_exit="$?"
    if [[ "$cfg_exit" -ne 0 || -z "$cfg" ]]; then
        log_error "Failed to load settings.dpi"
        exit 1
    fi
    DPI_GLOBAL="$cfg"

    workers_cfg="$("$CONFIG_GET_HELPER_GLOBAL" "settings.workers" 2>&1 || true)"
    if [[ -n "$workers_cfg" ]] && [[ "$workers_cfg" =~ ^[0-9]+$ ]]; then
        NUM_WORKERS_GLOBAL="$workers_cfg"
    else
        cpus="$(detect_logical_cpus)"
        NUM_WORKERS_GLOBAL="$cpus"
    fi

    cfg="$("$CONFIG_GET_HELPER_GLOBAL" "settings.skip_blank_pages" 2>&1 || true)"
    SKIP_BLANK_PAGES_GLOBAL="${cfg:-true}"

    # Fast-detection tuning from TOML or sensible defaults
    cfg="$("$CONFIG_GET_HELPER_GLOBAL" "blank_detection.fast_non_white_threshold" 2>&1 || true)"
    BLANK_FAST_THRESHOLD_GLOBAL="${cfg:-0.005}"

    cfg="$("$CONFIG_GET_HELPER_GLOBAL" "blank_detection.fast_fuzz_percent" 2>&1 || true)"
    BLANK_FAST_FUZZ_GLOBAL="${cfg:-5}"

    if [[ ! -d "$INPUT_DIR_GLOBAL" ]]; then
        log_error "Input directory does not exist: ${INPUT_DIR_GLOBAL}"
        exit 1
    fi
    mkdir -p "$OUTPUT_DIR_GLOBAL"

    if ! [[ "$DPI_GLOBAL" =~ ^[0-9]+$ ]] || [[ "$DPI_GLOBAL" -lt 1 ]]; then
        log_error "Invalid DPI: ${DPI_GLOBAL}"
        exit 1
    fi

    log_info "Configuration from project.toml:"
    log_info " Input: ${INPUT_DIR_GLOBAL}"
    log_info " Output: ${OUTPUT_DIR_GLOBAL}"
    log_info " DPI: ${DPI_GLOBAL}"
    log_info " Workers: ${NUM_WORKERS_GLOBAL}"
    log_info " Skip blanks: ${SKIP_BLANK_PAGES_GLOBAL}"
    log_info " Fast non-white threshold: ${BLANK_FAST_THRESHOLD_GLOBAL}"
    log_info " Fast fuzz percent: ${BLANK_FAST_FUZZ_GLOBAL}"
    print_line

    mapfile -t pdf_files < <(find "$INPUT_DIR_GLOBAL" -type f -name "*.pdf")
    array_len="${#pdf_files[@]}"
    if [[ "$array_len" -eq 0 ]]; then
        log_error "No PDF files found in ${INPUT_DIR_GLOBAL}"
        exit 1
    fi

    log_info "Found ${array_len} PDF file(s)"
    print_line

    processed=0
    failed=0
    total="$array_len"

    for pdf in "${pdf_files[@]}"; do
        log_info "Processing: $(basename "$pdf")"
        process_one_pdf_parallel "$pdf" "$DPI_GLOBAL" "$NUM_WORKERS_GLOBAL"
        process_exit="$?"
        if [[ "$process_exit" -eq 0 ]]; then
            processed=$((processed + 1))
        else
            failed=$((failed + 1))
        fi
        print_line
    done

    log_success "Complete: ${processed} successful, ${failed} failed, ${total} total"
}

main "$@"
