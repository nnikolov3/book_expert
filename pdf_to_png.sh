#!/usr/bin/env bash
# ================================================================================================
# SIMPLIFIED SERIAL PDF TO PNG CONVERTER
# Design: Niko Nikolov
# Simplified for serial processing with directory checking
# ================================================================================================

set -euo pipefail

# --- Global Variables ---
declare OUTPUT_DIR=""
declare INPUT_DIR=""
declare DPI=""
declare CONFIG_FILE=""
declare LOG_FILE=""

# ================================================================================================
# UTILITY FUNCTIONS
# ================================================================================================

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

get_config_optional()
{
	local key="$1"
	local default_value="${2:-}"
	local value
	value=$(yq -r ".${key} // \"\"" "$CONFIG_FILE" 2>/dev/null)
	[[ -z $value ]] && value="$default_value"
	echo "$value"
}

log_info()
{
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $*" | tee -a "${LOG_FILE:-/dev/stderr}"
}

log_error()
{
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "${LOG_FILE:-/dev/stderr}" >&2
}

check_dependencies()
{
	local -a deps=("yq" "ghostscript" "pdfinfo" "identify")
	for dep in "${deps[@]}"; do
		if ! command -v "$dep" &>/dev/null; then
			log_error "Required command not found: '$dep'. Please install it to continue."
			return 1
		fi
	done
	return 0
}

print_line()
{
	echo "========================================================================="
}

cleanup_and_exit()
{
	local exit_code=${1:-0}
	log_info "Exiting with code $exit_code"
	print_line
	exit "$exit_code"
}

# ================================================================================================
# DIRECTORY CHECKING FUNCTIONS
# ================================================================================================

count_files_in_dir()
{
	local dir="$1"
	local pattern="$2"

	if [[ -z $dir || -z $pattern ]]; then
		echo "0"
		return 1
	fi

	if [[ -d $dir ]]; then
		find "$dir" -maxdepth 1 -name "$pattern" -type f | wc -l
	else
		echo "0"
	fi
}

should_skip_pdf()
{
	local pdf_name="$1"
	local pdf_dir="$OUTPUT_DIR/$pdf_name"
	local png_dir="$pdf_dir/png"
	local text_dir="$pdf_dir/text"

	# Check if both directories exist
	if [[ ! -d $png_dir ]]; then
		echo "WARN: PNG directory does not exist"
		echo "INFO: Creating directory $png_dir"
		mkdir -p "$png_dir"
		print_line

	fi
	if [[ ! -d $text_dir ]]; then
		echo "WARN: TEXT directory does not exist"
		echo "INFO: Creating directory $text_dir"
		mkdir -p "$text_dir"
		print_line
	fi

	# Count files in each directory
	local png_count=0
	local text_count=0
	png_count=$(count_files_in_dir "$png_dir" "*.png")
	text_count=$(count_files_in_dir "$text_dir" "*.txt")

	# Skip if both directories have files and same count
	if [[ $png_count -gt 0 && $text_count -gt 0 && $png_count -eq $text_count ]]; then
		log_info "WARN: Skipping '$pdf_name': png ($png_count) and text ($text_count) files already exist"
		print_line
		return 0 # Skip
	fi

	return 1 # Don't skip
}

convert_pdf()
{
	local pdf_path="$1"
	local pdf_name
	pdf_name=$(basename "$pdf_path" .pdf)
	local final_png_dir="$OUTPUT_DIR/$pdf_name/png"

	log_info "INFO: --- Starting conversion for: $pdf_name ---"

	# Check if we should skip this PDF
	if should_skip_pdf "$pdf_name"; then
		return 0
	fi

	# Create output directory
	if ! mkdir -p "$final_png_dir"; then
		log_error "ERROR: Failed to create output directory: $final_png_dir"
		return 1
	fi

	# Get page count
	if ! num_pages=$(pdfinfo "$pdf_path" | awk '/Pages:/ {print $2}'); then
		log_error "ERROR: Failed to get page count for '$pdf_path'"
		print_line
		return 1
	fi

	if [[ $num_pages -eq 0 ]]; then
		log_error "ERROR: Invalid page count for '$pdf_path': $num_pages"
		print_line
		return 1
	fi

	log_info "INFO: Converting $num_pages pages from '$pdf_name'"
	print_line

	# Check for required variables
	if [[ -z $DPI ]]; then
		log_error "ERROR: DPI variable not set"

		return 1
	fi

	digits=4 # Zero-pad to 4 digits for consistency, e.g., page_0001.png

	mkdir -p "$final_png_dir"
	echo "INFO: Creating final directory"
	# Convert PDF to PNGs (Ghostscript)
	if ! ghostscript -dNOPAUSE -dBATCH -sDEVICE=png16m -r"$DPI" \
		-sOutputFile="${final_png_dir}/page_%0${digits}d.png" "$pdf_path"; then
		log_error "ERROR: GS failed"
		print_line
	fi

	log_info "--- Successfully converted '$pdf_name': Kept $processed_count, Skipped $skipped_count ---"
	return 0
}

# ================================================================================================
# MAIN EXECUTION
# ================================================================================================

main()
{
	# Initialize configuration
	CONFIG_FILE="$HOME/Dev/book_expert/project.toml"

	# Validate config file
	if [[ ! -f $CONFIG_FILE ]]; then
		log_error "ERROR: Configuration file not found: $CONFIG_FILE"
		cleanup_and_exit 1
	fi

	# Load configurations
	date +%c
	print_line
	log_info "Loading configuration from $CONFIG_FILE"
	print_line
	# Load log directory and create log file
	local log_dir
	if ! log_dir=$(get_config "logs_dir.pdf_to_png"); then
		log_error "ERROR: Failed to load logs_dir.pdf_to_png"
		cleanup_and_exit 1
	fi
	if ! mkdir -p "$log_dir" 2>/dev/null; then
		log_error "ERROR: Failed to create log directory: $log_dir"
		cleanup_and_exit 1
	fi
	LOG_FILE="$log_dir/log_$(date +'%Y%m%d_%H%M%S').log"
	if ! touch "$LOG_FILE" 2>/dev/null; then
		log_error "ERROR: Failed to create log file: $LOG_FILE"
		cleanup_and_exit 1
	fi

	log_info "PDF to PNG conversion process started"
	print_line

	# Load other configurations
	OUTPUT_DIR=$(get_config "paths.output_dir")
	INPUT_DIR=$(get_config "paths.input_dir")
	DPI=$(get_config "settings.dpi")

	# Validate directories
	if [[ ! -d $INPUT_DIR ]]; then
		log_error "Input directory does not exist: $INPUT_DIR"
		cleanup_and_exit 1
	fi
	if ! mkdir -p "$OUTPUT_DIR" 2>>"$LOG_FILE"; then
		log_error "Failed to create output directory: $OUTPUT_DIR"
		cleanup_and_exit 1
	fi

	# Validate numeric values
	for var in DPI; do
		if ! [[ ${!var} =~ ^[0-9]+$ ]] || ((${!var} < 0)); then
			log_error "$var must be a non-negative integer: ${!var}"
			cleanup_and_exit 1
		fi
	done

	log_info "Configuration loaded: INPUT_DIR=$INPUT_DIR, OUTPUT_DIR=$OUTPUT_DIR, DPI=$DPI"

	# Check dependencies
	if ! check_dependencies; then
		log_error "ERROR: Dependency check failed"
		print_line
		cleanup_and_exit 1
	fi

	local -a pdf_array
	log_info "INFO: Searching for PDF files in $INPUT_DIR"
	print_line

	# Store full paths in the array
	mapfile -t pdf_array < <(find "$INPUT_DIR" -type f -name "*.pdf")

	if [[ ${#pdf_array[@]} -eq 0 ]]; then
		log_error "ERROR: No PDF files found in $INPUT_DIR"
		print_line
		cleanup_and_exit 1
	fi

	log_info "SUCCESS: Found ${#pdf_array[@]} PDF file(s) to process"
	print_line

	# Process PDFs serially
	local processed_count=0
	local skipped_count=0
	local failed_count=0
	local total_files=${#pdf_array[@]}

	for pdf_path in "${pdf_array[@]}"; do
		# Extract just the filename without extension for display/logic
		local pdf_name
		pdf_name=$(basename "$pdf_path" .pdf)

		processed_count=$((processed_count + 1))
		log_info "INFO: Proceeding with '$pdf_name' ($processed_count of $total_files)"
		log_info "INFO: PATH $pdf_path"
		print_line

		if should_skip_pdf "$pdf_name"; then
			skipped_count=$((skipped_count + 1))
			echo "INFO: SKIPPING $pdf_name"
			print_line
			continue
		fi

		if convert_pdf "$pdf_path"; then
			log_info "SUCCESS: Successfully processed '$pdf_name'"
			print_line
		else
			log_error "ERROR: Failed to process '$pdf_path'"
			failed_count=$((failed_count + 1))
			print_line
		fi
	done

	trap - INT TERM
	log_info "INFO: Processing complete: Processed $((processed_count - skipped_count - failed_count)), Skipped $skipped_count, Failed $failed_count of $total_files"
	print_line
	cleanup_and_exit 0
}

main "$@"
