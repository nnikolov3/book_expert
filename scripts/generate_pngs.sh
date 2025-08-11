#!/usr/bin/env bash
# Parallel PDF -> PNG converter with lock-free per-core FIFO workers
# Design: Worker-per-core, round-robin page assignment, no shared outputs

set -euo pipefail

# ========== Global readonly configuration ==========
declare -r BLANK_PAGE_THRESHOLD_KB_GLOBAL=80
declare -r DIGITS_GLOBAL=4
declare -r DEVICE_GLOBAL="png16m"

# Config from helpers
declare -r CONFIG_GET_HELPER_GLOBAL="helpers/get_config_helper.sh"
declare -r LOGGER_HELPER_GLOBAL="helpers/logging_utils_helper.sh"

# ========== Global variables (initialized in main) ==========
declare INPUT_DIR_GLOBAL=""
declare OUTPUT_DIR_GLOBAL=""
declare DPI_GLOBAL=""
declare LOG_FILE_GLOBAL=""
declare LOG_DIR_GLOBAL=""
declare NUM_WORKERS_GLOBAL=0

# Arrays for FIFOs and PIDs
declare -a WORKER_FIFO_PATHS_GLOBAL=()
declare -a WORKER_PIDS_GLOBAL=()

# ========== Logging wrappers (populated after sourcing helper) ==========
function log_info() { :; }
function log_warn() { :; }
function log_error() { :; }
function log_success() { :; }
function print_line() { :; }

# ========== Utility functions ==========

function require_commands() {
    local -a deps=()
    local dep=""
    deps=("ghostscript" "pdfinfo" "stat" "awk" "sed" "tr" "head" "mkfifo" "uname" "getconf")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/stdout 2>/dev/stderr; then
            echo "ERROR: Required command not found: $dep" 1>&2
            exit 1
        fi
    done
}

# Linux-only logical CPU count with clean fallback to getconf
function detect_logical_cpus() {
    local cpus=""
    if command -v nproc >/dev/null 2>&1; then
        cpus="$(nproc --all)"
    else
        cpus="$(getconf _NPROCESSORS_ONLN)"
    fi

    if [[ -z "$cpus" ]] || ! [[ "$cpus" =~ ^[0-9]+$ ]] || [[ "$cpus" -lt 1 ]]; then
        echo "ERROR: Failed to detect logical CPU count" 1>&2
        exit 1
    fi
    printf '%s\n' "$cpus"
}

function get_file_size_kb() {
    local file_path=""
    local size_bytes=""
    file_path="$1"
    if [[ -f "$file_path" ]]; then
        size_bytes="$(stat -c%s "$file_path" 2>/dev/stderr || stat -f%z "$file_path" 2>/dev/stderr || true)"
        if [[ -n "$size_bytes" ]]; then
            printf '%s\n' "$((size_bytes / 1024))"
            return 0
        fi
    fi
    printf '%s\n' "0"
    return 0
}

function is_blank_page() {
    local png_path=""
    local file_size_kb=""
    png_path="$1"
    file_size_kb="$(get_file_size_kb "$png_path")"
    if [[ "$file_size_kb" -lt "$BLANK_PAGE_THRESHOLD_KB_GLOBAL" ]]; then
        return 0
    fi
    return 1
}

function count_files_in_dir() {
    local dir=""
    local pattern=""
    dir="$1"
    pattern="$2"
    if [[ -z "$dir" || -z "$pattern" ]]; then
        printf '%s\n' "0"
        return 1
    fi
    if [[ -d "$dir" ]]; then
        find "$dir" -maxdepth 1 -type f -name "$pattern" | wc -l | tr -d ' '
    else
        printf '%s\n' "0"
    fi
}

# ========== Ghostscript per-page render ==========
function render_page() {
    local pdf_path=""
    local dpi=""
    local device=""
    local page_index=""
    local out_png=""
    local gs_out=""
    local gs_exit=""
    local first=""
    local last=""

    pdf_path="$1"
    dpi="$2"
    device="$3"
    page_index="$4"
    out_png="$5"

    first="$page_index"
    last="$page_index"

    # Render a single page to a specific PNG file using Ghostscript[11][18]
    gs_out="$(ghostscript \
        -dNOPAUSE \
        -dBATCH \
        -sDEVICE="$device" \
        -r"$dpi" \
        -dFirstPage="$first" \
        -dLastPage="$last" \
        -o "$out_png" \
        "$pdf_path" 2>&1)"
    gs_exit="$?"

    if [[ "$gs_exit" -ne 0 ]]; then
        printf '%s\n' "Ghostscript failed for page $page_index: $gs_out" 1>&2
        return "$gs_exit"
    fi

    # Verify file exists
    if [[ ! -f "$out_png" ]]; then
        printf '%s\n' "Missing output file after Ghostscript for page $page_index: $out_png" 1>&2
        return 1
    fi
    return 0
}

# ========== Worker implementation ==========
function worker_loop() {
    # All locals declared at top
    local fifo_path=""
    local pdf_path=""
    local dpi=""
    local device=""
    local out_dir=""
    local digits=""
    local line=""
    local page_idx=""
    local out_png=""
    local page_padded=""
    local exit_any=0

    fifo_path="$1"
    pdf_path="$2"
    dpi="$3"
    device="$4"
    out_dir="$5"
    digits="$6"

    # Each worker reads page indices from its dedicated FIFO and renders exactly one page per job
    while IFS= read -r line; do
        if [[ "$line" == "STOP" ]]; then
            break
        fi
        page_idx="$line"
        # zero-pad page index
        page_padded="$(printf "%0${digits}d" "$page_idx")"
        out_png="${out_dir}/page_${page_padded}.png"
        if ! render_page "$pdf_path" "$dpi" "$device" "$page_idx" "$out_png"; then
            exit_any=1
            # Continue to read remaining commands to avoid leaving writer blocked
        fi
    done <"$fifo_path"

    return "$exit_any"
}

# ========== FIFO setup / teardown ==========
function create_worker_fifos() {
    local workers=""
    local i=0
    local fifo_path=""
    workers="$1"
    WORKER_FIFO_PATHS_GLOBAL=()
    for i in $(seq 1 "$workers"); do
        fifo_path="$(mktemp -u)"
        # enforce a recognizable suffix
        fifo_path="${fifo_path}.fifo.$$.$i"
        if [[ -e "$fifo_path" ]]; then
            echo "ERROR: FIFO path already exists unexpectedly: $fifo_path" 1>&2
            exit 1
        fi
        if ! mkfifo "$fifo_path"; then
            echo "ERROR: Failed to create FIFO: $fifo_path" 1>&2
            exit 1
        fi
        WORKER_FIFO_PATHS_GLOBAL+=("$fifo_path")
    done
}

function start_workers() {
    local workers=""
    local i=0
    local pid=""
    local fifo=""
    local pdf_path=""
    local dpi=""
    local device=""
    local out_dir=""
    local digits=""

    workers="$1"
    pdf_path="$2"
    dpi="$3"
    device="$4"
    out_dir="$5"
    digits="$6"

    WORKER_PIDS_GLOBAL=()
    for i in $(seq 1 "$workers"); do
        fifo="${WORKER_FIFO_PATHS_GLOBAL[$((i - 1))]}"
        # Start worker in background with dedicated FIFO
        # shellcheck disable=SC2091
        (worker_loop "$fifo" "$pdf_path" "$dpi" "$device" "$out_dir" "$digits") &
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
    workers="${#WORKER_FIFO_PATHS_GLOBAL[@]}"

    # Send STOP sentinel to each worker FIFO
    for i in $(seq 1 "$workers"); do
        fifo="${WORKER_FIFO_PATHS_GLOBAL[$((i - 1))]}"
        # Writer open will block if no reader; workers are running and reading
        printf '%s\n' "STOP" >"$fifo"
    done

    # Wait for workers to exit
    for pid in "${WORKER_PIDS_GLOBAL[@]}"; do
        if ! wait "$pid"; then
            fail_count=$((fail_count + 1))
        fi
    done

    # Remove FIFOs
    for fifo in "${WORKER_FIFO_PATHS_GLOBAL[@]}"; do
        if [[ -p "$fifo" ]]; then
            rm -f "$fifo"
        fi
    done

    if [[ "$fail_count" -ne 0 ]]; then
        echo "ERROR: $fail_count worker(s) reported errors" 1>&2
        return 1
    fi
    return 0
}

# ========== Round-robin scheduler ==========
function schedule_pages_round_robin() {
    local total_pages=""
    local workers=""
    local page=0
    local idx=0
    local fifo=""

    total_pages="$1"
    workers="$2"

    # Assign page 1->worker1, page2->worker2, ..., pageN->workerN, then wrap[5]
    for page in $(seq 1 "$total_pages"); do
        idx=$(((page - 1) % workers))
        fifo="${WORKER_FIFO_PATHS_GLOBAL[$idx]}"
        printf '%s\n' "$page" >"$fifo"
    done
}

# ========== Blank page cleanup ==========
function remove_blank_pages_in_dir() {
    local png_dir=""
    local blank_count=0
    local removed_files=""
    local filename=""

    png_dir="$1"
    log_info "Checking for blank pages in $png_dir"

    # Find and test each png
    while IFS= read -r -d '' path; do
        if is_blank_page "$path"; then
            filename="$(basename "$path")"
            if rm "$path"; then
                blank_count=$((blank_count + 1))
                if [[ -n "$removed_files" ]]; then
                    removed_files="${removed_files}, ${filename}"
                else
                    removed_files="${filename}"
                fi
                log_info "Removed blank page: ${filename} (${BLANK_PAGE_THRESHOLD_KB_GLOBAL}KB threshold)"
            else
                log_warn "Failed to remove blank page: ${filename}"
            fi
        fi
    done < <(find "$png_dir" -type f -name "*.png" -print0)

    if [[ "$blank_count" -gt 0 ]]; then
        log_success "Removed $blank_count blank page(s): $removed_files"
    else
        log_info "No blank pages detected"
    fi
}

# ========== PDF processing ==========
function process_one_pdf_parallel() {
    local pdf_path=""
    local pdf_name=""
    local out_dir=""
    local dpi=""
    local device=""
    local digits=""
    local info_out=""
    local pages=""
    local mkdir_out=""
    local mkdir_exit=""
    local workers=""
    local generated_count=""
    local stop_ok=0

    pdf_path="$1"
    dpi="$2"
    device="$3"
    digits="$4"
    workers="$5"

    pdf_name="$(basename "$pdf_path" .pdf)"
    out_dir="${OUTPUT_DIR_GLOBAL}/${pdf_name}/png"

    log_info "Preparing output directory for ${pdf_name}: ${out_dir}"
    mkdir_out="$(mkdir -p "$out_dir" 2>&1 || true)"
    mkdir_exit="$?"
    if [[ "$mkdir_exit" -ne 0 ]]; then
        log_error "Failed to create output directory: ${out_dir}: ${mkdir_out}"
        return 1
    fi

    # Get page count using pdfinfo[11]
    info_out="$(pdfinfo "$pdf_path" 2>&1 || true)"
    if [[ -z "$info_out" ]]; then
        log_error "Failed to get PDF info for ${pdf_path}"
        return 1
    fi
    pages="$(printf '%s\n' "$info_out" | awk '/^Pages:/ {print $2}')"
    if [[ -z "$pages" ]]; then
        log_error "Failed to parse page count for ${pdf_path}"
        return 1
    fi
    if ! [[ "$pages" =~ ^[0-9]+$ ]] || [[ "$pages" -lt 1 ]]; then
        log_error "Invalid page count ${pages} for ${pdf_path}"
        return 1
    fi

    log_info "Converting ${pages} pages from ${pdf_name} with ${workers} workers"

    # Setup FIFOs and start workers
    create_worker_fifos "$workers"
    start_workers "$workers" "$pdf_path" "$dpi" "$device" "$out_dir" "$digits"

    # Round-robin schedule pages to workers[5]
    schedule_pages_round_robin "$pages" "$workers"

    # Stop workers and verify exit status
    if stop_workers; then
        stop_ok=1
    else
        stop_ok=0
    fi
    if [[ "$stop_ok" -ne 1 ]]; then
        log_error "One or more workers failed for ${pdf_name}"
        return 1
    fi

    # Verify generated count
    generated_count="$(count_files_in_dir "$out_dir" "*.png")"
    log_info "Generated ${generated_count} PNG files before blank-page removal"

    # Blank page cleanup
    remove_blank_pages_in_dir "$out_dir"

    # Final count
    generated_count="$(count_files_in_dir "$out_dir" "*.png")"
    log_success "Completed ${pdf_name}: ${generated_count} PNG files after processing"
    return 0
}

# ========== Main ==========
function main() {
    # Local declarations
    local start_time=""
    local cfg=""
    local cfg_exit=""
    local array_len=0
    local -a pdf_files=()
    local pdf=""
    local processed=0
    local failed=0
    local total=0
    local cpus=""

    require_commands

    start_time="$(date +%c)"

    # Load log dir from config
    cfg="$("$CONFIG_GET_HELPER_GLOBAL" "logs_dir.pdf_to_png" 2>&1 || true)"
    cfg_exit="$?"
    if [[ "$cfg_exit" -ne 0 || -z "$cfg" ]]; then
        echo "ERROR: Failed to load logs_dir.pdf_to_png: ${cfg}" 1>&2
        exit 1
    fi
    LOG_DIR_GLOBAL="$cfg"
    if ! mkdir -p "$LOG_DIR_GLOBAL"; then
        echo "ERROR: Failed to create log directory: $LOG_DIR_GLOBAL" 1>&2
        exit 1
    fi
    LOG_FILE_GLOBAL="${LOG_DIR_GLOBAL}/log_$(date +'%Y%m%d_%H%M%S').log"

    # Source logger
    # shellcheck disable=SC1090
    source "$LOGGER_HELPER_GLOBAL"
    if ! touch "$LOG_FILE_GLOBAL"; then
        echo "ERROR: Failed to create log file: $LOG_FILE_GLOBAL" 1>&2
        exit 1
    fi

    log_info "PDF->PNG parallel conversion start: ${start_time}"
    print_line

    # Load paths.output_dir
    cfg="$("$CONFIG_GET_HELPER_GLOBAL" "paths.output_dir" 2>&1 || true)"
    cfg_exit="$?"
    if [[ "$cfg_exit" -ne 0 || -z "$cfg" ]]; then
        log_error "Failed to load paths.output_dir: ${cfg}"
        exit 1
    fi
    OUTPUT_DIR_GLOBAL="$cfg"

    # Load paths.input_dir
    cfg="$("$CONFIG_GET_HELPER_GLOBAL" "paths.input_dir" 2>&1 || true)"
    cfg_exit="$?"
    if [[ "$cfg_exit" -ne 0 || -z "$cfg" ]]; then
        log_error "Failed to load paths.input_dir: ${cfg}"
        exit 1
    fi
    INPUT_DIR_GLOBAL="$cfg"

    # Load settings.dpi
    cfg="$("$CONFIG_GET_HELPER_GLOBAL" "settings.dpi" 2>&1 || true)"
    cfg_exit="$?"
    if [[ "$cfg_exit" -ne 0 || -z "$cfg" ]]; then
        log_error "Failed to load settings.dpi: ${cfg}"
        exit 1
    fi
    DPI_GLOBAL="$cfg"

    # Validate paths and DPI
    if [[ ! -d "$INPUT_DIR_GLOBAL" ]]; then
        log_error "Input directory does not exist: ${INPUT_DIR_GLOBAL}"
        exit 1
    fi
    if ! mkdir -p "$OUTPUT_DIR_GLOBAL"; then
        log_error "Failed to create output directory: ${OUTPUT_DIR_GLOBAL}"
        exit 1
    fi
    if ! [[ "$DPI_GLOBAL" =~ ^[0-9]+$ ]] || [[ "$DPI_GLOBAL" -lt 1 ]]; then
        log_error "DPI must be a positive integer: ${DPI_GLOBAL}"
        exit 1
    fi

    # Detect logical CPUs for worker count[12][15]
    cpus="$(detect_logical_cpus)"
    if ! [[ "$cpus" =~ ^[0-9]+$ ]] || [[ "$cpus" -lt 1 ]]; then
        log_error "Invalid logical CPU count: ${cpus}"
        exit 1
    fi
    NUM_WORKERS_GLOBAL="$cpus"
    log_info "Using ${NUM_WORKERS_GLOBAL} workers (logical CPUs detected)[12][15]"

    log_info "Blank page threshold: ${BLANK_PAGE_THRESHOLD_KB_GLOBAL}KB"
    log_info "Device: ${DEVICE_GLOBAL}"
    print_line

    # Discover PDFs
    mapfile -t pdf_files < <(find "$INPUT_DIR_GLOBAL" -type f -name "*.pdf")
    array_len="${#pdf_files[@]}"
    if [[ "$array_len" -eq 0 ]]; then
        log_error "No PDF files found in ${INPUT_DIR_GLOBAL}"
        exit 1
    fi
    log_info "Found ${array_len} PDF file(s) to process"
    print_line

    processed=0
    failed=0
    total="$array_len"

    for pdf in "${pdf_files[@]}"; do
        log_info "Processing $(basename "$pdf")"
        if process_one_pdf_parallel "$pdf" "$DPI_GLOBAL" "$DEVICE_GLOBAL" "$DIGITS_GLOBAL" "$NUM_WORKERS_GLOBAL"; then
            processed=$((processed + 1))
        else
            failed=$((failed + 1))
        fi
        print_line
    done

    log_success "Processing complete: Successful ${processed}, Failed ${failed}, Total ${total}"
}

main "$@"
