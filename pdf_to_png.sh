#!/usr/bin/env bash
# ================================================================================================
# PDF TO PNG CONVERTER
# Design: Niko Nikolov
# Code: Various LLMs, fixed by Grok
# ================================================================================================
# ## Code Guidelines:
# - Declare variables before assignment to prevent undefined variable errors.
# - Use explicit if/then/fi blocks for readability.
# - Ensure all if/fi blocks are closed correctly.
# - Use atomic file operations (mv, flock) to prevent race conditions in parallel processing.
# - Avoid mixing API calls.
# - Lint with shellcheck for correctness.
# - Use grep -q for silent checks.
# - Check for unbound variables with set -u.
# - Clean up unused variables and maintain detailed comments.
# - Avoid unreachable code or redundant commands.
# - Keep code concise, clear, and self-documented.
# - Avoid 'useless cat' use cmd < file.
# - If not in a function use declare not local.
# - For Ghostscript use `ghostscript <cmd>`
# - Use `rsync` not cp.
# - Initialize all variables.
# - Code should be self documenting.
#
# COMMENTS SHOULD NOT BE REMOVED, INCONCISTENCIES SHOULD BE UPDATED WHEN DETECTED
# USE MARKDOWN WITHIN THE COMMENT BLOCKS FOR COMMENTS
# ================================================================================================

set -euo pipefail

# --- Global Variables ---
# Initialized to empty strings to avoid unbound variable errors
declare OUTPUT_DIR=""
declare INPUT_DIR=""
declare DPI=""
declare WORKERS=""
declare CONFIG_FILE=""
declare LOG_DIR=""
declare LOG_FILE=""
declare PROCESSING_DIR=""
declare MAX_RETRIES=""
declare RETRY_DELAY_SECONDS=""
declare BLANK_THRESHOLD=""
declare SKIP_BLANK_PAGES=""

# ================================================================================================
# UTILITY FUNCTIONS
# ================================================================================================
# ## get_config()
# ## Purpose
# Retrieves a configuration value from the config file using yq.
# ## Parameters
# - `$1`: Configuration key to retrieve.
# ## Returns
# - Prints the value or empty string if not found.
# - Returns 1 on error, 0 on success.
get_config()
{
	local key="$1"
	local value
	value=$(yq -r ".${key} // \"\"" "$CONFIG_FILE" 2>/dev/null)
	if [[ -z $value ]]; then
		log_error "Missing or empty configuration key '$key' in $CONFIG_FILE"
		return 1
	fi
	echo "$value"
	return 0
}

# ## get_config_optional()
# ## Purpose
# Retrieves an optional configuration value with a default if not set.
# ## Parameters
# - `$1`: Configuration key to retrieve.
# - `$2`: Default value (optional).
# ## Returns
# - Prints the value or default value.
get_config_optional()
{
	local key="$1"
	local default_value="${2:-}"
	local value
	value=$(yq -r ".${key} // \"\"" "$CONFIG_FILE" 2>/dev/null)
	[[ -z $value ]] && value="$default_value"
	echo "$value"
}

# ## log_info()
# ## Purpose
# Logs an info message to stdout and the log file.
# ## Parameters
# - `$*`: Message to log.
log_info()
{
	# FIX: Check if LOG_FILE is writable before logging
	if [[ -n $LOG_FILE && -w $LOG_FILE ]] || [[ -z $LOG_FILE ]]; then
		echo "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $*" | tee -a "${LOG_FILE:-/dev/stderr}"
	else
		echo "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $*" >&2
	fi
}

# ## log_error()
# ## Purpose
# Logs an error message to stderr and the log file.
# ## Parameters
# - `$*`: Error message to log.
log_error()
{
	# FIX: Check if LOG_FILE is writable before logging
	if [[ -n $LOG_FILE && -w $LOG_FILE ]]; then
		echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "$LOG_FILE" >&2
	else
		echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
	fi
}

# ## check_dependencies()
# ## Purpose
# Checks for required external commands.
# ## Returns
# - 0 if all dependencies are present, 1 otherwise.
check_dependencies()
{
	local -a deps=("yq" "ghostscript" "pdfinfo" "mktemp" "identify")
	for dep in "${deps[@]}"; do
		if ! command -v "$dep" &>/dev/null; then
			log_error "Required command not found: '$dep'. Please install it to continue."
			return 1
		fi
	done
	return 0
}

# ## cleanup_and_exit()
# ## Purpose
# Cleans up resources and exits with the specified code.
# ## Parameters
# - `$1`: Exit code (default 0).
cleanup_and_exit()
{
	local exit_code=${1:-0}
	log_info "Cleaning up resources..."

	if [[ -n ${PROCESSING_DIR:-} && -d $PROCESSING_DIR ]]; then
		rm -rf "$PROCESSING_DIR" 2>>"${LOG_FILE:-/dev/stderr}" || log_error "Failed to remove '$PROCESSING_DIR'."
	fi

	log_info "Cleanup finished. Exiting with code $exit_code"
	exit "$exit_code"
}

# ## cleanup_processing_dir()
# ## Purpose
# Cleans up the processing directory without exiting.
cleanup_processing_dir()
{
	if [[ -n ${PROCESSING_DIR:-} && -d $PROCESSING_DIR ]]; then
		rm -rf "$PROCESSING_DIR" 2>>"${LOG_FILE:-/dev/stderr}" || log_error "Failed to remove '$PROCESSING_DIR'."
		unset PROCESSING_DIR
	fi
}

# ================================================================================================
# BLANK PAGE DETECTION
# ================================================================================================

# ## is_png_blank()
# ## Purpose
# Detects if a PNG image is blank based on pixel standard deviation.
# ## Parameters
# - `$1`: Full path to the PNG file.
# ## Returns
# - 0 if blank, 1 if not blank.
is_png_blank()
{
	local png_path="$1"
	local std_dev

	std_dev=$(identify -format "%[standard-deviation]" "$png_path" 2>>"${LOG_FILE:-/dev/stderr}")
	if [[ -z $std_dev ]]; then
		log_error "Could not determine standard deviation for '$png_path'. Keeping the file."
		return 1
	fi

	local std_dev_int
	std_dev_int=$(printf "%.0f" "$std_dev")
	if ((std_dev_int < BLANK_THRESHOLD)); then
		log_info "Detected blank page: '$png_path' (std dev: $std_dev, threshold: $BLANK_THRESHOLD)"
		return 0
	fi

	return 1
}

# ================================================================================================
# PROCESSING FUNCTIONS
# ================================================================================================

# ## setup_processing_dir()
# ## Purpose
# Creates a temporary processing directory for a PDF.
# ## Parameters
# - `$1`: PDF stem (filename without extension).
# ## Returns
# - 0 on success, 1 on failure.
setup_processing_dir()
{
	local pdf_stem="$1"
	local base_path
	if ! base_path=$(get_config "processing_dir.pdf_to_png"); then
		return 1
	fi

	if [[ ! -d $base_path ]]; then
		log_info "Creating base processing directory: $base_path"
		if ! mkdir -p "$base_path" 2>>"${LOG_FILE:-/dev/stderr}"; then
			log_error "Failed to create base processing directory: $base_path"
			return 1
		fi
	fi

	PROCESSING_DIR=$(mktemp -d -p "$base_path" "${pdf_stem}_XXXXXX" 2>>"${LOG_FILE:-/dev/stderr}")
	if [[ ! -d $PROCESSING_DIR ]]; then
		log_error "Failed to create processing directory"
		return 1
	fi

	log_info "Processing directory created at: $PROCESSING_DIR"
	return 0
}

# ## process_worker_block()
# ## Purpose
# Converts a range of PDF pages to PNGs with blank page detection.
# ## Parameters
# - `$1`: Worker ID.
# - `$2`: PDF file path.
# - `$3`: Start page number.
# - `$4`: End page number.
# - `$5`: Output directory for PNGs.
# - `$6`: Zero-padding length for filenames.
# ## Returns
# - 0 on success, 1 on failure.
process_worker_block()
{
	local worker_id="$1"
	local pdf_path="$2"
	local start_page="$3"
	local end_page="$4"
	local output_dir="$5"
	local page_len="$6"
	local pdf_name
	pdf_name=$(basename "$pdf_path" .pdf)
	local worker_temp_dir
	worker_temp_dir=$(mktemp -d -p "$PROCESSING_DIR" "worker_${worker_id}_XXXXXX" 2>>"${LOG_FILE:-/dev/stderr}")

	log_info "Worker $worker_id: Processing pages $start_page-$end_page for '$pdf_name'."

	local attempt=0
	while ((attempt < MAX_RETRIES)); do
		if ghostscript -q -sDEVICE=png16m -r"$DPI" \
			-dTextAlphaBits=4 -dGraphicsAlphaBits=4 \
			-dFirstPage="$start_page" -dLastPage="$end_page" \
			-sOutputFile="$worker_temp_dir/page_%0${page_len}d.png" \
			-dNOPAUSE -dBATCH "$pdf_path" 2>>"${LOG_FILE:-/dev/stderr}"; then
			break
		fi
		((attempt++))
		log_info "Worker $worker_id: Ghostscript failed (attempt $attempt/$MAX_RETRIES). Retrying in ${RETRY_DELAY_SECONDS}s..."
		sleep "$RETRY_DELAY_SECONDS"
	done

	if ((attempt == MAX_RETRIES)); then
		log_error "Worker $worker_id: Ghostscript failed permanently for pages $start_page-$end_page."
		rm -rf "$worker_temp_dir" 2>>"${LOG_FILE:-/dev/stderr}"
		return 1
	fi

	local current_page_num="$start_page"
	local -a generated_files
	mapfile -d '' -t generated_files < <(find "$worker_temp_dir" -name "*.png" -type f -print0 | sort -zV)

	local processed_count=0
	local skipped_count=0

	for file_path in "${generated_files[@]}"; do
		local target_filename
		target_filename=$(printf "page_%0${page_len}d.png" "$current_page_num")

		if [[ $SKIP_BLANK_PAGES == "true" ]] && is_png_blank "$file_path"; then
			log_info "Worker $worker_id: Skipping blank page $current_page_num"
			((skipped_count++))
			rm -f "$file_path" 2>>"${LOG_FILE:-/dev/stderr}"
		else
			if ! mv "$file_path" "$output_dir/$target_filename" 2>>"${LOG_FILE:-/dev/stderr}"; then
				log_error "Worker $worker_id: Failed to move '$file_path' to '$output_dir/$target_filename'."
				rm -rf "$worker_temp_dir" 2>>"${LOG_FILE:-/dev/stderr}"
				return 1
			fi
			((processed_count++))
		fi

		((current_page_num++))
	done

	rm -rf "$worker_temp_dir" 2>>"${LOG_FILE:-/dev/stderr}"
	log_info "Worker $worker_id: Successfully processed pages $start_page-$end_page. Kept: $processed_count, Skipped: $skipped_count."
	return 0
}

# ## convert_pdf()
# ## Purpose
# Converts a single PDF to PNGs using parallel workers.
# ## Parameters
# - `$1`: PDF file path.
# ## Returns
# - 0 on success, 1 on failure.
convert_pdf()
{
	local pdf_path="$1"
	local pdf_name
	pdf_name=$(basename "$pdf_path" .pdf)
	local final_png_dir="$OUTPUT_DIR/$pdf_name/png"

	log_info "--- Starting conversion for: $pdf_name ---"

	if [[ -d $final_png_dir ]]; then
		log_info "Removing existing output directory: $final_png_dir"
		if ! rm -rf "$final_png_dir" 2>>"${LOG_FILE:-/dev/stderr}"; then
			log_error "Failed to remove existing output directory: $final_png_dir"
			return 1
		fi
	fi

	if ! mkdir -p "$final_png_dir" 2>>"${LOG_FILE:-/dev/stderr}"; then
		log_error "Failed to create output directory: $final_png_dir"
		return 1
	fi

	local num_pages
	if ! num_pages=$(pdfinfo "$pdf_path" 2>>"${LOG_FILE:-/dev/stderr}" | grep -E "^Pages:" | awk '{print $2}'); then
		log_error "Failed to execute pdfinfo for '$pdf_path'."
		return 1
	fi
	if [[ -z $num_pages || $num_pages -le 0 ]]; then
		log_error "Invalid page count for '$pdf_path': $num_pages"
		return 1
	fi

	local page_len=${#num_pages}
	((page_len < 4)) && page_len=4

	if ! setup_processing_dir "$pdf_name"; then
		log_error "Failed to set up processing directory for '$pdf_name'."
		return 1
	fi

	local temp_png_dir="$PROCESSING_DIR/png"
	if ! mkdir -p "$temp_png_dir" 2>>"${LOG_FILE:-/dev/stderr}"; then
		log_error "Failed to create temporary PNG directory: $temp_png_dir"
		return 1
	fi

	log_info "Distributing $num_pages pages across $WORKERS workers."
	if [[ $SKIP_BLANK_PAGES == "true" ]]; then
		log_info "Blank page detection enabled (threshold: $BLANK_THRESHOLD)."
	fi

	local -a worker_pids=()
	local pages_per_worker=$(((num_pages + WORKERS - 1) / WORKERS))
	for ((worker = 0; worker < WORKERS; worker++)); do
		local start_page=$((worker * pages_per_worker + 1))
		local end_page=$((start_page + pages_per_worker - 1))

		if ((start_page > num_pages)); then
			break
		fi
		((end_page > num_pages)) && end_page=$num_pages

		(
			if ! process_worker_block "$worker" "$pdf_path" "$start_page" "$end_page" "$temp_png_dir" "$page_len"; then
				log_error "Worker $worker failed for '$pdf_path'."
				exit 1
			fi
		) &
		worker_pids+=($!)
	done

	local failed=0
	for pid in "${worker_pids[@]}"; do
		if ! wait "$pid"; then
			((failed++))
		fi
	done

	if ((failed > 0)); then
		log_error "$failed worker(s) failed during conversion of '$pdf_path'. Check logs."
		return 1
	fi

	local png_count
	png_count=$(find "$temp_png_dir" -maxdepth 1 -name "page_*.png" -type f | wc -l)

	if ((png_count == 0)); then
		log_error "No PNG files generated for '$pdf_path' after processing."
		return 1
	fi

	log_info "Generated $png_count PNG file(s) from $num_pages PDF page(s)."
	log_info "Copying $png_count PNGs to final destination: $final_png_dir"
	if ! rsync -a "$temp_png_dir/" "$final_png_dir/" 2>>"${LOG_FILE:-/dev/stderr}"; then
		log_error "Failed to copy PNGs to '$final_png_dir'."
		return 1
	fi

	log_info "--- Successfully converted '$pdf_name' ---"
	return 0
}

# ================================================================================================
# MAIN EXECUTION
# ================================================================================================
main()
{
	# FIX: Initialize logging early to capture all messages
	CONFIG_FILE="$HOME/Dev/book_expert/project.toml"
	LOG_FILE="/tmp/pdf_to_png_$(date +'%Y%m%d_%H%M%S').log"
	if ! touch "$LOG_FILE" 2>/dev/null; then
		log_error "Failed to create temporary log file: $LOG_FILE"
		exit 1
	fi

	log_info "Initializing PDF to PNG conversion process."

	# FIX: Disable set -e early to catch all errors
	set +e

	# FIX: Validate config file
	if [[ ! -f $CONFIG_FILE ]]; then
		log_error "Configuration file not found: $CONFIG_FILE"
		cleanup_and_exit 1
	fi

	# Set up trap for cleanup
	trap 'cleanup_and_exit 130' INT TERM

	# Load and validate configurations
	log_info "Loading configuration from $CONFIG_FILE"
	if ! LOG_DIR=$(get_config "logs_dir.pdf_to_png"); then
		log_error "Failed to load logs_dir.pdf_to_png"
		cleanup_and_exit 1
	fi
	# FIX: Update LOG_FILE to use LOG_DIR
	NEW_LOG_FILE="$LOG_DIR/log_$(date +'%Y%m%d_%H%M%S').log"
	if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
		log_error "Failed to create log directory: $LOG_DIR"
		cleanup_and_exit 1
	fi
	if ! mv "$LOG_FILE" "$NEW_LOG_FILE" 2>/dev/null; then
		log_error "Failed to move log file to $NEW_LOG_FILE"
		cleanup_and_exit 1
	fi
	LOG_FILE="$NEW_LOG_FILE"
	log_info "Log file moved to: $LOG_FILE"

	if ! OUTPUT_DIR=$(get_config "paths.output_dir"); then
		log_error "Failed to load paths.output_dir"
		cleanup_and_exit 1
	fi
	if [[ ! -d $OUTPUT_DIR ]]; then
		log_info "Creating output directory: $OUTPUT_DIR"
		if ! mkdir -p "$OUTPUT_DIR" 2>>"$LOG_FILE"; then
			log_error "Failed to create output directory: $OUTPUT_DIR"
			cleanup_and_exit 1
		fi
	fi

	if ! INPUT_DIR=$(get_config "paths.input_dir"); then
		log_error "Failed to load paths.input_dir"
		cleanup_and_exit 1
	fi
	if [[ ! -d $INPUT_DIR ]]; then
		log_error "Input directory does not exist: $INPUT_DIR"
		cleanup_and_exit 1
	fi

	if ! DPI=$(get_config "settings.dpi"); then
		log_error "Failed to load settings.dpi"
		cleanup_and_exit 1
	fi
	if ! WORKERS=$(get_config "settings.workers"); then
		log_error "Failed to load settings.workers"
		cleanup_and_exit 1
	fi
	if ! MAX_RETRIES=$(get_config "retry.max_retries"); then
		log_error "Failed to load retry.max_retries"
		cleanup_and_exit 1
	fi
	if ! RETRY_DELAY_SECONDS=$(get_config "retry.retry_delay_seconds"); then
		log_error "Failed to load retry.retry_delay_seconds"
		cleanup_and_exit 1
	fi
	SKIP_BLANK_PAGES=$(get_config_optional "settings.skip_blank_pages" "true")
	BLANK_THRESHOLD=$(get_config_optional "settings.blank_threshold" "1000")

	# FIX: Simplified numeric validation
	for var in DPI WORKERS MAX_RETRIES RETRY_DELAY_SECONDS BLANK_THRESHOLD; do
		if ! [[ ${!var} =~ ^[0-9]+$ ]] || ((${!var} < 0)); then
			log_error "$var must be a non-negative integer: ${!var}"
			cleanup_and_exit 1
		fi
	done
	if ((WORKERS == 0)); then
		log_error "WORKERS must be greater than 0"
		cleanup_and_exit 1
	fi

	log_info "Configuration loaded: INPUT_DIR=$INPUT_DIR, OUTPUT_DIR=$OUTPUT_DIR, DPI=$DPI, WORKERS=$WORKERS"

	if ! check_dependencies; then
		log_error "Dependency check failed."
		cleanup_and_exit 1
	fi

	# Find PDF files
	local -a pdf_files
	log_info "Searching for PDF files in $INPUT_DIR"
	if ! mapfile -d '' -t pdf_files < <(find "$INPUT_DIR" -maxdepth 1 -name "*.pdf" -type f -print0 | sort -z); then
		log_error "Failed to search for PDF files in $INPUT_DIR"
		cleanup_and_exit 1
	fi
	if [[ ${#pdf_files[@]} -eq 0 ]]; then
		log_error "No PDF files found in input directory: $INPUT_DIR"
		cleanup_and_exit 1
	fi

	log_info "Found ${#pdf_files[@]} PDF file(s) to process."
	log_info "PDF files to process: ${pdf_files[*]}"

	local processed_count=0
	local total_files=${#pdf_files[@]}
	local failed_count=0

	# FIX: Explicit loop entry logging
	log_info "Entering PDF processing loop"
	for pdf_path in "${pdf_files[@]}"; do
		log_info "Processing PDF: $pdf_path"
		local pdf_name
		pdf_name=$(basename "$pdf_path" .pdf)

		((processed_count++))
		log_info "Processing '$pdf_name' ($processed_count of $total_files)."

		if convert_pdf "$pdf_path"; then
			log_info "Successfully processed '$pdf_name'. Remaining PDFs: $((total_files - processed_count))"
		else
			log_error "Failed to process '$pdf_path'. Continuing with next PDF."
			((failed_count++))
		fi

		cleanup_processing_dir
		log_info "Processing directory cleaned up for '$pdf_name'."

		if ((processed_count < total_files)); then
			log_info "Continuing to next PDF..."
		else
			log_info "All PDFs processed. Preparing for final cleanup."
		fi
	done

	trap - INT TERM
	log_info "All tasks completed. Successfully processed $((processed_count - failed_count)) of $total_files PDF file(s). Failed: $failed_count."
	cleanup_and_exit 0
}

main "$@"
