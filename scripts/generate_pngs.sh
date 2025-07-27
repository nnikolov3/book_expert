#!/usr/bin/env bash

# Design: Niko Nikolov
# Code: Niko and LLMs

set -euo pipefail

# --- Global Variables ---
declare OUTPUT_DIR=""
declare INPUT_DIR=""
declare DPI=""
declare CONFIG_FILE=""
declare LOG_FILE=""
declare BLANK_PAGE_THRESHOLD_KB=80

# ================================================================================================
# UTILITY FUNCTIONS
# ================================================================================================

print_line()
{
	echo "======================================================================="
}

log_info()
{
	local timestamp=""
	timestamp=$(date '+%Y-%m-%d %H:%M:%S')
	local message="[$timestamp] INFO: $*"
	echo "$message"
	echo "$message" >>"$LOG_FILE"
}

log_warn()
{
	local timestamp=""
	timestamp=$(date '+%Y-%m-%d %H:%M:%S')
	local message="[$timestamp] WARN: $*"
	echo "$message"
	echo "$message" >>"$LOG_FILE"
	print_line
}

log_success()
{
	local timestamp=""
	timestamp=$(date '+%Y-%m-%d %H:%M:%S')
	local message="[$timestamp] SUCCESS: $*"
	echo "$message"
	echo "$message" >>"$LOG_FILE"
	print_line
}

log_error()
{
	local timestamp=""
	timestamp=$(date '+%Y-%m-%d %H:%M:%S')
	local message="[$timestamp] ERROR: $*"
	echo "$message"
	echo "$message" >>"$LOG_FILE"
	print_line
	return 1
}

get_config()
{
	local key="$1"
	local value
	value=$(yq -r ".${key} // \"\"" "$CONFIG_FILE" 2>/dev/null)
	if [[ -z $value ]]; then
		echo "Missing or empty configuration key '$key' in $CONFIG_FILE"
		return 1
	fi
	echo "$value"
	return 0
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

get_file_size_kb()
{
	local file_path="$1"
	if [[ -f $file_path ]]; then
		local size_bytes
		size_bytes=$(stat -c%s "$file_path" 2>/dev/null || stat -f%z "$file_path" 2>/dev/null)
		if [[ -n $size_bytes ]]; then
			echo $((size_bytes / 1024))
		else
			echo "0"
		fi
	else
		echo "0"
	fi
}

is_blank_page()
{
	local png_path="$1"
	local file_size_kb
	file_size_kb=$(get_file_size_kb "$png_path")

	if [[ $file_size_kb -lt $BLANK_PAGE_THRESHOLD_KB ]]; then
		return 0 # Is blank
	else
		return 1 # Not blank
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

remove_blank_pages()
{
	local png_dir="$1"
	local blank_count=0
	local removed_files=""

	log_info "Checking for blank pages in $png_dir"

	# Find all PNG files and check if they're blank
	while IFS= read -r -d '' png_path; do
		if is_blank_page "$png_path"; then
			local filename
			filename=$(basename "$png_path")
			if rm "$png_path"; then
				blank_count=$((blank_count + 1))
				if [[ -n $removed_files ]]; then
					removed_files="$removed_files, $filename"
				else
					removed_files="$filename"
				fi
				log_info "Removed blank page: $filename (${BLANK_PAGE_THRESHOLD_KB}KB threshold)"
			else
				log_warn "Failed to remove blank page: $filename"
			fi
		fi
	done < <(find "$png_dir" -name "*.png" -type f -print0)

	if [[ $blank_count -gt 0 ]]; then
		log_success "Removed $blank_count blank page(s): $removed_files"
	else
		log_info "No blank pages detected"
	fi

	return 0
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

	log_info "Generated $generated_count PNG files before blank page removal"

	# Remove blank pages
	remove_blank_pages "$final_png_dir"

	# Count remaining files after blank page removal
	local final_count
	final_count=$(count_files_in_dir "$final_png_dir" "*.png")

	log_success "Successfully converted '$pdf_name': $final_count PNG files remaining after processing"
	return 0
}

# ================================================================================================
# MAIN EXECUTION
# ================================================================================================

main()
{
	# Initialize configuration
	CONFIG_FILE="$PWD/project.toml"

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
	print_line
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
	log_info "Blank page threshold: ${BLANK_PAGE_THRESHOLD_KB}KB"

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

		local current_file=$((processed_count + skipped_count + failed_count + 1))
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
		print_line
	done

	log_success "Processing complete: Successful $processed_count, Skipped $skipped_count, Failed $failed_count of $total_files"
	cleanup_and_exit 0
}

main "$@"
