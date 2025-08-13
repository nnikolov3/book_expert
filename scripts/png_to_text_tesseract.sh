#!/usr/bin/env bash
set -euo pipefail

# png_to_text_tesseract.sh
# Parallel PNG-to-text conversion using Tesseract OCR with robust worker management

# ===========================
# Configuration (readonly)
# ===========================
declare -r CONFIG_HELPER_GLOBAL="helpers/get_config_helper.sh"
declare -r LOGGER_HELPER_GLOBAL="helpers/logging_utils_helper.sh"
declare -r CLEAN_HELPER_GLOBAL="helpers/clean_text_with_sed_helper.sh"
declare -r REQUIRE_DEPS_HELPER_GLOBAL="helpers/require_dependencies_helper.sh"

# ===========================
# Global variables (from config)
# ===========================
declare INPUT_DIR_GLOBAL=""
declare OUTPUT_DIR_GLOBAL=""
declare PROCESSING_DIR_GLOBAL=""
declare LOG_DIR_GLOBAL=""
declare LOG_FILE=""

declare DPI_GLOBAL=""
declare WORKERS_GLOBAL=0
declare TESS_LANG_GLOBAL=""
declare TESS_OEM_GLOBAL=""
declare TESS_PSM_GLOBAL=""

# ===========================
# Runtime state
# ===========================
declare -a PDF_NAMES_GLOBAL=()
declare -a WORKER_FIFO_PATHS_GLOBAL=()
declare -a WORKER_PIDS_GLOBAL=()

# ===========================
# Logger stubs (populated after sourcing)
# ===========================
function log_info() { :; }
function log_warn() { :; }
function log_error() { :; }
function log_success() { :; }
function print_line() { :; }

# ===========================
# Core functions
# ===========================
function load_configuration() {
    # locals
    local cfg=""
    local cfg_exit=""

    cfg=$("$CONFIG_HELPER_GLOBAL" "logs_dir.png_to_text" 2>&1)
    cfg_exit="$?"
    if [[ "$cfg_exit" -ne 0 || -z "$cfg" ]]; then
        echo "ERROR: Failed to load logs_dir.png_to_text: $cfg" >&2
        exit 1
    fi
    LOG_DIR_GLOBAL="$cfg"

    cfg=$("$CONFIG_HELPER_GLOBAL" "paths.input_dir" 2>&1)
    cfg_exit="$?"
    if [[ "$cfg_exit" -ne 0 || -z "$cfg" ]]; then
        echo "ERROR: Failed to load paths.input_dir: $cfg" >&2
        exit 1
    fi
    INPUT_DIR_GLOBAL="$cfg"

    cfg=$("$CONFIG_HELPER_GLOBAL" "paths.output_dir" 2>&1)
    cfg_exit="$?"
    if [[ "$cfg_exit" -ne 0 || -z "$cfg" ]]; then
        echo "ERROR: Failed to load paths.output_dir: $cfg" >&2
        exit 1
    fi
    OUTPUT_DIR_GLOBAL="$cfg"

    cfg=$("$CONFIG_HELPER_GLOBAL" "processing_dir.png_to_text" 2>&1)
    cfg_exit="$?"
    if [[ "$cfg_exit" -ne 0 || -z "$cfg" ]]; then
        echo "ERROR: Failed to load processing_dir.png_to_text: $cfg" >&2
        exit 1
    fi
    PROCESSING_DIR_GLOBAL="$cfg"

    cfg=$("$CONFIG_HELPER_GLOBAL" "settings.dpi" 2>&1)
    if [[ -z "$cfg" ]]; then
        DPI_GLOBAL="300"
    else
        DPI_GLOBAL="$cfg"
    fi

    cfg=$("$CONFIG_HELPER_GLOBAL" "settings.workers" 2>&1)
    if [[ -z "$cfg" ]]; then
        WORKERS_GLOBAL="$(getconf _NPROCESSORS_ONLN)"
    else
        WORKERS_GLOBAL="$cfg"
    fi

    cfg=$("$CONFIG_HELPER_GLOBAL" "tesseract.language" 2>&1)
    if [[ -z "$cfg" ]]; then
        TESS_LANG_GLOBAL="eng+equ"
    else
        TESS_LANG_GLOBAL="$cfg"
    fi

    cfg=$("$CONFIG_HELPER_GLOBAL" "tesseract.oem" 2>&1)
    if [[ -z "$cfg" ]]; then
        TESS_OEM_GLOBAL="3"
    else
        TESS_OEM_GLOBAL="$cfg"
    fi

    cfg=$("$CONFIG_HELPER_GLOBAL" "tesseract.psm" 2>&1)
    if [[ -z "$cfg" ]]; then
        TESS_PSM_GLOBAL="3"
    else
        TESS_PSM_GLOBAL="$cfg"
    fi
}

function setup_logging() {
    # locals
    local mkdir_result=""
    local mkdir_exit=""
    local touch_result=""
    local touch_exit=""

    mkdir_result=$(mkdir -p "$LOG_DIR_GLOBAL" 2>&1)
    mkdir_exit="$?"
    if [[ "$mkdir_exit" -ne 0 ]]; then
        echo "ERROR: Cannot create log directory: $mkdir_result" >&2
        exit 1
    fi

    LOG_FILE="${LOG_DIR_GLOBAL}/log_$(date +'%Y%m%d_%H%M%S').log"
    export LOG_FILE

    # Load logger which defines log_info/log_warn/log_error/log_success/print_line
    # shellcheck source=/dev/null
    source "$LOGGER_HELPER_GLOBAL"

    touch_result=$(touch "$LOG_FILE" 2>&1)
    touch_exit="$?"
    if [[ "$touch_exit" -ne 0 ]]; then
        echo "ERROR: Cannot create log file: $touch_result" >&2
        exit 1
    fi
}

function validate_directories() {
    # locals
    local mkdir_result=""
    local mkdir_exit=""

    if [[ ! -d "$INPUT_DIR_GLOBAL" ]]; then
        echo "ERROR: Input directory does not exist: $INPUT_DIR_GLOBAL" >&2
        exit 1
    fi

    mkdir_result=$(mkdir -p "$OUTPUT_DIR_GLOBAL" "$PROCESSING_DIR_GLOBAL" 2>&1)
    mkdir_exit="$?"
    if [[ "$mkdir_exit" -ne 0 ]]; then
        echo "ERROR: Cannot create output directories: $mkdir_result" >&2
        exit 1
    fi
}

function discover_pdf_names() {
    # locals
    local pdf_file=""

    for pdf_file in "$INPUT_DIR_GLOBAL"/*.pdf; do
        if [[ -f "$pdf_file" ]]; then
            PDF_NAMES_GLOBAL+=("$(basename "$pdf_file" .pdf)")
        fi
    done

    if [[ "${#PDF_NAMES_GLOBAL[@]}" -eq 0 ]]; then
        log_warn "discover_pdf_names: No PDF files found in $INPUT_DIR_GLOBAL"
        return 1
    fi

    return 0
}

function process_single_png() {
    # ALL local variables at the top
    local png_file="$1"
    local output_file="$2"
    local tesseract_result=""
    local tesseract_exit=""
    local clean_result=""
    local clean_exit=""
    local temp_file=""

    if [[ -z "$png_file" || -z "$output_file" ]]; then
        log_error "process_single_png: Missing arguments"
        return 1
    fi
    if [[ ! -f "$png_file" ]]; then
        log_error "process_single_png: PNG not found: $png_file"
        return 1
    fi

    temp_file=$(mktemp)
    if [[ -z "$temp_file" || ! -f "$temp_file" ]]; then
        log_error "process_single_png: Failed to create temp file"
        return 1
    fi

    tesseract_result=$(tesseract "$png_file" stdout \
        -l "$TESS_LANG_GLOBAL" \
        --dpi "$DPI_GLOBAL" \
        --oem "$TESS_OEM_GLOBAL" \
        --psm "$TESS_PSM_GLOBAL" 2>&1)
    tesseract_exit="$?"

    if [[ "$tesseract_exit" -ne 0 ]]; then
        rm -f "$temp_file"
        log_error "process_single_png: Tesseract failed for $png_file: $tesseract_result"
        return 1
    fi

    if ! printf '%s\n' "$tesseract_result" >"$temp_file"; then
        rm -f "$temp_file"
        log_error "process_single_png: Failed writing OCR to temp file for $png_file"
        return 1
    fi

    # Cleaner accepts a file path and prints cleaned text to stdout
    clean_result=$("$CLEAN_HELPER_GLOBAL" "$temp_file" 2>&1)
    clean_exit="$?"

    if [[ "$clean_exit" -eq 0 && -n "$clean_result" ]]; then
        if ! printf '%s\n' "$clean_result" >"$output_file"; then
            rm -f "$temp_file"
            log_error "process_single_png: Failed to write cleaned text to $output_file"
            return 1
        fi
    else
        log_warn "process_single_png: Cleaner failed or empty for $png_file; using raw OCR"
        if ! printf '%s\n' "$tesseract_result" >"$output_file"; then
            rm -f "$temp_file"
            log_error "process_single_png: Failed to write raw OCR to $output_file"
            return 1
        fi
    fi

    rm -f "$temp_file"
    return 0
}

function worker_loop() {
    # ALL local variables at the top
    local fifo="$1"
    local output_dir="$2"
    local task=""
    local png_file=""
    local output_file=""
    local base_name=""

    if [[ -z "$fifo" || -z "$output_dir" ]]; then
        log_error "worker_loop: Missing fifo or output_dir"
        exit 1
    fi

    while IFS= read -r task <"$fifo"; do
        if [[ "$task" == "STOP" ]]; then
            log_info "worker_loop: Received STOP on $fifo"
            break
        fi

        png_file="$task"
        base_name=$(basename "$png_file" .png)
        output_file="$output_dir/${base_name}.txt"

        if [[ ! -f "$png_file" ]]; then
            log_error "worker_loop: PNG does not exist: $png_file"
            exit 1
        fi

        if ! process_single_png "$png_file" "$output_file"; then
            log_error "worker_loop: Failed processing $png_file -> $output_file"
            exit 1
        fi
        log_info "worker_loop: Completed $png_file -> $output_file"
    done
}

function start_workers() {
    # Start N workers, each with its own FIFO, and record PIDs and FIFO paths
    # ALL local variables at the top
    local num_workers="$1"
    local output_dir="$2"
    local i=""
    local fifo=""
    local mkfifo_result=""
    local mkfifo_exit=""
    local pid=""
    local worker_index=0

    if [[ -z "$num_workers" || -z "$output_dir" ]]; then
        log_error "start_workers: Missing arguments num_workers or output_dir"
        return 1
    fi
    if [[ "$num_workers" -le 0 ]]; then
        log_error "start_workers: num_workers must be > 0 (got: $num_workers)"
        return 1
    fi

    for i in $(seq 1 "$num_workers"); do
        worker_index=$i
        fifo=$(mktemp -u "/tmp/png_to_text_worker_${worker_index}.XXXXXXXX.fifo")

        mkfifo_result=$(mkfifo "$fifo" 2>&1)
        mkfifo_exit="$?"
        if [[ "$mkfifo_exit" -ne 0 ]]; then
            log_error "start_workers: Failed to create FIFO $fifo: $mkfifo_result"
            # Attempt cleanup of any previous resources
            stop_workers || true
            return 1
        fi

        WORKER_FIFO_PATHS_GLOBAL+=("$fifo")

        worker_loop "$fifo" "$output_dir" &
        pid="$!"
        if [[ -z "$pid" || "$pid" -le 0 ]]; then
            log_error "start_workers: Failed to start worker $worker_index for FIFO $fifo"
            stop_workers || true
            return 1
        fi

        WORKER_PIDS_GLOBAL+=("$pid")
        log_info "start_workers: Started worker $worker_index pid=$pid fifo=$fifo"
    done

    return 0
}

function schedule_files() {
    # Distribute files round-robin to worker FIFOs
    # ALL local variables at the top
    local -a png_files=("$@")
    local fifo_count="${#WORKER_FIFO_PATHS_GLOBAL[@]}"
    local fifo_index=0
    local file=""
    local fifo=""
    local printf_exit=""
    local i=""

    if [[ "$fifo_count" -eq 0 ]]; then
        log_error "schedule_files: No workers available (fifo_count=0)"
        return 1
    fi
    if [[ "${#png_files[@]}" -eq 0 ]]; then
        log_warn "schedule_files: No PNG files to schedule"
        return 0
    fi

    for i in "${!png_files[@]}"; do
        file="${png_files[$i]}"
        fifo="${WORKER_FIFO_PATHS_GLOBAL[$fifo_index]}"

        if [[ ! -p "$fifo" ]]; then
            log_error "schedule_files: FIFO missing or not a pipe: $fifo"
            return 1
        fi

        # Write the task; if writer gets EPIPE (worker died), report and fail fast
        if ! printf '%s\n' "$file" >"$fifo"; then
            printf_exit="$?"
            log_error "schedule_files: Failed to write task to FIFO $fifo (exit=$printf_exit) for file: $file"
            return 1
        fi

        fifo_index=$(((fifo_index + 1) % fifo_count))
    done

    return 0
}

function stop_workers() {
    # Gracefully stop workers, wait, and cleanup FIFOs
    # ALL local variables at the top
    local fifo=""
    local pid=""
    local wait_exit=""
    local failed_count=0
    local i=""

    # Send STOP to all FIFOs if they exist
    for i in "${!WORKER_FIFO_PATHS_GLOBAL[@]}"; do
        fifo="${WORKER_FIFO_PATHS_GLOBAL[$i]}"
        if [[ -p "$fifo" ]]; then
            if ! printf 'STOP\n' >"$fifo"; then
                log_warn "stop_workers: Failed to send STOP to FIFO $fifo (likely worker exited)"
            fi
        fi
    done

    # Wait for workers
    for i in "${!WORKER_PIDS_GLOBAL[@]}"; do
        pid="${WORKER_PIDS_GLOBAL[$i]}"
        if [[ -n "$pid" ]]; then
            if ! wait "$pid"; then
                wait_exit="$?"
                failed_count=$((failed_count + 1))
                log_error "stop_workers: Worker pid=$pid exited with code $wait_exit"
            else
                log_info "stop_workers: Worker pid=$pid exited cleanly"
            fi
        fi
    done

    # Cleanup FIFOs
    for i in "${!WORKER_FIFO_PATHS_GLOBAL[@]}"; do
        fifo="${WORKER_FIFO_PATHS_GLOBAL[$i]}"
        if [[ -p "$fifo" ]]; then
            if ! rm -f "$fifo"; then
                log_warn "stop_workers: Failed to remove FIFO $fifo"
            else
                log_info "stop_workers: Removed FIFO $fifo"
            fi
        fi
    done

    # Reset arrays for safety on subsequent runs
    WORKER_FIFO_PATHS_GLOBAL=()
    WORKER_PIDS_GLOBAL=()

    if [[ "$failed_count" -gt 0 ]]; then
        log_error "stop_workers: $failed_count workers reported failures"
        return 1
    fi
    return 0
}

function process_pdf_name() {
    # ALL local variables at the top
    local pdf_name="$1"
    local pdf_dir="$OUTPUT_DIR_GLOBAL/$pdf_name/png"
    local output_dir="$OUTPUT_DIR_GLOBAL/$pdf_name/text"
    local -a png_files=()
    local find_result=""
    local find_exit=""
    local file=""

    if [[ -z "$pdf_name" ]]; then
        log_error "process_pdf_name: Missing pdf_name"
        return 1
    fi

    if ! mkdir -p "$output_dir"; then
        log_error "process_pdf_name: Failed to create output_dir: $output_dir"
        return 1
    fi

    find_result=$(find "$pdf_dir" -maxdepth 1 -name "*.png" -type f 2>&1)
    find_exit="$?"
    if [[ "$find_exit" -ne 0 ]]; then
        log_error "process_pdf_name: find failed in $pdf_dir: $find_result"
        return 1
    fi

    while IFS= read -r file; do
        if [[ -n "$file" ]]; then
            png_files+=("$file")
        fi
    done <<<"$find_result"

    if [[ "${#png_files[@]}" -eq 0 ]]; then
        log_warn "process_pdf_name: No PNG files in $pdf_dir"
        return 0
    fi

    log_info "process_pdf_name: $pdf_name -> ${#png_files[@]} files, workers=$WORKERS_GLOBAL"

    if ! start_workers "$WORKERS_GLOBAL" "$output_dir"; then
        log_error "process_pdf_name: start_workers failed for $pdf_name"
        stop_workers || true
        return 1
    fi

    if ! schedule_files "${png_files[@]}"; then
        log_error "process_pdf_name: schedule_files failed for $pdf_name"
        stop_workers || true
        return 1
    fi

    if ! stop_workers; then
        log_error "process_pdf_name: stop_workers reported failures for $pdf_name"
        return 1
    fi

    log_success "process_pdf_name: Completed $pdf_name"
    return 0
}

function main() {
    # locals
    local processed=0
    local failed=0
    local total=0
    local pdf_name=""

    # Dependencies, include sed for cleaner
    "$REQUIRE_DEPS_HELPER_GLOBAL" tesseract yq mkfifo getconf find sed

    load_configuration
    setup_logging
    validate_directories

    print_line
    log_info "Start png_to_text_tesseract"
    log_info "Workers: $WORKERS_GLOBAL"
    log_info "Tesseract: lang=$TESS_LANG_GLOBAL, oem=$TESS_OEM_GLOBAL, psm=$TESS_PSM_GLOBAL"
    print_line

    if ! discover_pdf_names; then
        log_error "main: No PDF names to process"
        exit 1
    fi

    total="${#PDF_NAMES_GLOBAL[@]}"
    for pdf_name in "${PDF_NAMES_GLOBAL[@]}"; do
        if process_pdf_name "$pdf_name"; then
            processed=$((processed + 1))
        else
            failed=$((failed + 1))
            # Defensive: ensure no leftover workers
            stop_workers || true
        fi
    done

    print_line
    log_success "png_to_text_tesseract complete: Successful $processed, Failed $failed, Total $total"
    print_line
}

main "$@"
