#!/usr/bin/env bash
# ================================================================================================
# SIMPLIFIED SERIAL PDF TO PNG CONVERTER
# Design: Niko Nikolov
# Simplified for serial processing with directory checking
# ------------------------------------------------------------------------------------
# ## Code Guidelines to LLMs
# - Declare (and assign separetly) variables to prevent undefined variable errors.
# - Use explicit if/then/fi blocks for readability.
# - Ensure all if/fi blocks are closed correctly.
# - Use atomic file operations (mv, flock) to prevent race conditions in parallel processing.
# - Avoid mixing API calls.
# - Lint with shellcheck correctness.
# - Use grep -q for silent checks.
# - Check for unbound variables with set -u.
# - Clean up unused variables and maintain detailed comments.
# - Avoid unreachable code or redundant commands.
# - Keep code concise, clear, and self-documented.
# - Avoid 'useless cat' use cmd < file.
# - If not in a function use declare not local.
# - Use `rsync` not cp.
# - Initialize all variables.
# - Code should be self-documenting.
# - Flows should have solid retry logic.
# - Do more with less. Do not add code for the sake of adding code. It should have clear purpose.
# - No hardcoded values.
# - DO NOT USE if <cmd>; then. Rather, use output=$(cmd) if $output; then
# - DO NOT USE 2>>"$LOG_FILE"
# - DO NOT USE ((i++)) instead use i=$((i + 1))
# - DO NOT IGNORE the guidelines
# - AVOID Redirections 2>/dev/null
# - Declare / assign each variable on its own line
# COMMENTS SHOULD NOT BE REMOVED, INCONSISTENCIES SHOULD BE UPDATED WHEN DETECTED
# ------------------------------------------------------------------------------------
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

log_info()
{
	local message
	message="INFO: $(date +%c) $*"
	echo "$message"
	echo "$message" >>"$LOG_FILE"
	print_line
}

log_error()
{
	local message
	message="ERROR: $(date +%c) $*"
	echo "$message"
	echo "$message" >>"$LOG_FILE"
	print_line
}

log_warn()
{
	local message
	message="WARN: $(date +%c) $*"
	echo "$message"
	echo "$message" >>"$LOG_FILE"
	print_line
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
	local line="========================================================================="
	echo "$line"
	echo "$line" >>"$LOG_FILE"
}

cleanup_and_exit()
{
	local exit_code=${1:-0}
	log_info "Exiting with code $exit_code"
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

	# If PNG directory exists and has PNG files, skip with warning
	if [[ -d $png_dir ]]; then
		local png_count
		png_count=$(count_files_in_dir "$png_dir" "*.png")
		if [[ $png_count -gt 0 ]]; then
			log_warn "Skipping '$pdf_name': PNG directory exists with $png_count files. Remove '$png_dir' to regenerate PNGs."
			return 0 # Skip
		fi
	fi

	return 1 # Don't skip
}

convert_pdf()
{
	local pdf_path="$1"
	local pdf_name
	pdf_name=$(basename "$pdf_path" .pdf)
	local final_png_dir="$OUTPUT_DIR/$pdf_name/png"

	log_info "Starting conversion for: $pdf_name"

	# Check if we should skip this PDF
	if should_skip_pdf "$pdf_name"; then
		return 0
	fi

	# Create output directory
	if ! mkdir -p "$final_png_dir"; then
		log_error "Failed to create output directory: $final_png_dir"
		return 1
	fi

	# Get page count
	local pdf_info_output
	local num_pages
	pdf_info_output=$(pdfinfo "$pdf_path" 2>/dev/null)
	if [[ -z $pdf_info_output ]]; then
		log_error "Failed to get PDF info for '$pdf_path'"
		return 1
	fi
	num_pages=$(echo "$pdf_info_output" | awk '/Pages:/ {print $2}')
	if [[ -z $num_pages ]]; then
		log_error "Failed to extract page count from PDF info for '$pdf_path'"
		return 1
	fi

	if [[ $num_pages -eq 0 ]]; then
		log_error "Invalid page count for '$pdf_path': $num_pages"
		return 1
	fi

	log_info "Converting $num_pages pages from '$pdf_name'"

	# Check for required variables
	if [[ -z $DPI ]]; then
		log_error "DPI variable not set"
		return 1
	fi

	local digits=4 # Zero-pad to 4 digits for consistency, e.g., page_0001.png

	log_info "Creating final directory: $final_png_dir"

	# Convert PDF to PNGs (Ghostscript)
	if ! ghostscript -dNOPAUSE -dBATCH -sDEVICE=png16m -r"$DPI" \
		-sOutputFile="${final_png_dir}/page_%0${digits}d.png" "$pdf_path"; then
		log_error "Ghostscript conversion failed for '$pdf_name'"
		return 1
	fi

	# Count generated files for verification
	local generated_count
	generated_count=$(count_files_in_dir "$final_png_dir" "*.png")

	log_info "Successfully converted '$pdf_name': Generated $generated_count PNG files"
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
		echo "ERROR: Configuration file not found: $CONFIG_FILE"
		exit 1
	fi

	# Load configurations
	local start_time
	start_time=$(date +%c)

	# Load log directory and create log file
	local log_dir
	local config_result
	config_result=$(get_config "logs_dir.pdf_to_png" 2>/dev/null)
	if [[ $? -ne 0 || -z $config_result ]]; then
		echo "ERROR: Failed to load logs_dir.pdf_to_png"
		exit 1
	fi
	log_dir="$config_result"
	if ! mkdir -p "$log_dir"; then
		echo "ERROR: Failed to create log directory: $log_dir"
		exit 1
	fi
	LOG_FILE="$log_dir/log_$(date +'%Y%m%d_%H%M%S').log"
	if ! touch "$LOG_FILE" 2>/dev/null; then
		echo "ERROR: Failed to create log file: $LOG_FILE"
		exit 1
	fi

	log_info "PDF to PNG conversion process started at $start_time"
	log_info "Loading configuration from $CONFIG_FILE"

	# Load other configurations
	config_result=$(get_config "paths.output_dir" 2>/dev/null)
	if [[ $? -ne 0 || -z $config_result ]]; then
		log_error "Failed to load paths.output_dir"
		cleanup_and_exit 1
	fi
	OUTPUT_DIR="$config_result"

	config_result=$(get_config "paths.input_dir" 2>/dev/null)
	if [[ $? -ne 0 || -z $config_result ]]; then
		log_error "Failed to load paths.input_dir"
		cleanup_and_exit 1
	fi
	INPUT_DIR="$config_result"

	config_result=$(get_config "settings.dpi" 2>/dev/null)
	if [[ $? -ne 0 || -z $config_result ]]; then
		log_error "Failed to load settings.dpi"
		cleanup_and_exit 1
	fi
	DPI="$config_result"

	# Validate directories
	if [[ ! -d $INPUT_DIR ]]; then
		log_error "Input directory does not exist: $INPUT_DIR"
		cleanup_and_exit 1
	fi
	if ! mkdir -p "$OUTPUT_DIR"; then
		log_error "Failed to create output directory: $OUTPUT_DIR"
		cleanup_and_exit 1
	fi

	# Validate numeric values
	if ! [[ $DPI =~ ^[0-9]+$ ]] || [[ $DPI -lt 1 ]]; then
		log_error "DPI must be a positive integer: $DPI"
		cleanup_and_exit 1
	fi

	log_info "Configuration loaded: INPUT_DIR=$INPUT_DIR, OUTPUT_DIR=$OUTPUT_DIR, DPI=$DPI"

	# Check dependencies
	if ! check_dependencies; then
		log_error "Dependency check failed"
		cleanup_and_exit 1
	fi

	local -a pdf_array
	log_info "Searching for PDF files in $INPUT_DIR"

	# Store full paths in the array
	mapfile -t pdf_array < <(find "$INPUT_DIR" -type f -name "*.pdf")

	if [[ ${#pdf_array[@]} -eq 0 ]]; then
		log_error "No PDF files found in $INPUT_DIR"
		cleanup_and_exit 1
	fi

	log_info "Found ${#pdf_array[@]} PDF file(s) to process"

	# Process PDFs serially
	local processed_count=0
	local skipped_count=0
	local failed_count=0
	local total_files=${#pdf_array[@]}

	for pdf_path in "${pdf_array[@]}"; do
		# Extract just the filename without extension for display/logic
		local pdf_name
		pdf_name=$(basename "$pdf_path" .pdf)

		local current_file=$((processed_count + 1))
		log_info "Processing '$pdf_name' ($current_file of $total_files)"
		log_info "Full path: $pdf_path"

		if should_skip_pdf "$pdf_name"; then
			skipped_count=$((skipped_count + 1))
		elif convert_pdf "$pdf_path"; then
			processed_count=$((processed_count + 1))
		else
			log_error "Failed to process '$pdf_path'"
			failed_count=$((failed_count + 1))
		fi
	done

	local successful_count=$((total_files - skipped_count - failed_count))
	log_info "Processing complete: Successful $successful_count, Skipped $skipped_count, Failed $failed_count of $total_files"
	cleanup_and_exit 0
}

main "$@"
