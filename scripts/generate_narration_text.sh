#!/bin/bash
# ================================================================================================
# Design: Niko Nikolov
# Code: Niko and LLMs

# Enable strict error handling
set -euo pipefail

# ================================================================================================
# CONFIGURATION AND GLOBAL VARIABLES
# ================================================================================================
declare -r CONFIG_FILE="$PWD/../project.toml"

# Global variables loaded from config
declare INPUT_DIR=""
declare OUTPUT_DIR=""
declare LOG_DIR=""
declare PROCESSING_DIR=""
declare LOG_FILE=""
declare -a FINAL_TEXT_DIRS_GLOBAL=()
# Export the content to a global variable for use elsewhere
declare CONCATENATED_CONTENT=""
declare CONCATENATED_FILE_PATH=""

# ================================================================================================
# UTILITY FUNCTIONS
# ================================================================================================

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

log()
{
	log_info "$@"
}

print_line()
{
	echo "===================================================================="
}

# ================================================================================================
# MAIN PROCESSING FUNCTIONS
# ================================================================================================

is_final_text_ready()
{
	local -a pdf_array=("$@")
	local final_text_path
	local concat_path
	local concat_count
	local final_text_count

	FINAL_TEXT_DIRS_GLOBAL=()

	for pdf_name in "${pdf_array[@]}"; do
		log_info "Checking document: $pdf_name"
		final_text_path="$OUTPUT_DIR/$pdf_name/final_text"
		concat_path="$OUTPUT_DIR/$pdf_name/concat"

		if [[ -d $final_text_path ]]; then
			if [[ -d $concat_path ]]; then
				concat_count=$(find "$concat_path" -type f | wc -l)
				if [[ $concat_count -eq 1 ]]; then
					log_warn "$pdf_name has already a concatenated text"
					log_info "If you want to generate a new file, remove the directory"
					continue
				fi
			fi

			final_text_count=$(find "$final_text_path" -type f | wc -l)

			if [[ $final_text_count -gt 0 ]]; then
				log_info "FINAL_TEXT: $final_text_count"
				log_success "adding directory for processing"
				FINAL_TEXT_DIRS_GLOBAL+=("$final_text_path")
			else
				log_info "FINAL_TEXT: $final_text_count"
				log_warn "Review $final_text_path"
			fi
		else
			log_warn "Confirm path $final_text_path"
		fi
	done

	if [[ ${#FINAL_TEXT_DIRS_GLOBAL[@]} -eq 0 ]]; then
		log_error "No directories to process with valid final text files"
		exit 1
	else
		log_success "Found directories to process"
		return 0
	fi
}

get_last_two_dirs()
{
	local full_path="$1"
	local parent_dir
	parent_dir=$(basename "$(dirname "$full_path")")
	local current_dir
	current_dir=$(basename "$full_path")
	echo "$parent_dir/$current_dir"
}

create_single_file()
{
	local processing_dir="$1"
	local concat_file_dir="$2"
	local final_text_path="$3"

	# Input validation
	if [[ -z $processing_dir ]] || [[ ! -d $processing_dir ]]; then
		log_error "Invalid directory $processing_dir"
		return 1
	fi
	if [[ -z $final_text_path ]]; then
		log_error "Invalid directory for final text"
		return 1
	fi
	if [[ -z $concat_file_dir ]] || [[ ! -d $concat_file_dir ]]; then
		log_error "Invalid directory for the concatenated file"
		return 1
	fi

	# Copy files with progress and error handling
	rsync -a "$final_text_path/" "$processing_dir/"

	# Verify copy integrity
	local rsync_output
	rsync_output=$(rsync -a --checksum --dry-run "$final_text_path/" "$processing_dir/")
	local exit_status="$?"
	if [[ exit_status -eq 0 ]]; then
		if [[ -z $rsync_output ]]; then
			log_success "STAGING COMPLETE"
		else
			log_warn "Files may differ:"
			log_info "$rsync_output"
		fi
	else
		log_error "Failed to verify staging integrity"
		rm -rf "$processing_dir"
		return 1
	fi

	# Look for text files with various extensions
	declare -a text_array=()
	mapfile -t text_array < <(find "$processing_dir" -type f -name "*.txt" | sort -V)
	local number_files="${#text_array[@]}"
	if [[ number_files -eq 0 ]]; then
		log_error "No TEXT files found in $processing_dir"
		log_info "DEBUG: Directory structure (first 5 files):"
		find "$processing_dir" -type f | head -5 | while read -r file; do log_info "$file"; done
		return 1
	else
		log_success "Found ${#text_array[@]} text files. Continue Processing ..."
	fi

	local concat_filename="concatenated.txt"
	local concat_filepath="$concat_file_dir/$concat_filename"
	local concatenated_content=""

	log_info "Starting file concatenation..."

	# Clear the output file
	true >"$concat_filepath"

	# Process each file in the sorted order
	for file in "${text_array[@]}"; do
		local basename_file
		basename_file=$(basename "$file")
		log_info "Processing file: $basename_file"

		# Append file content
		if cat "$file" >>"$concat_filepath"; then
			log_success "Added $basename_file to concatenated file"
		else
			log_error "Failed to append $basename_file"
			return 1
		fi

		# Add spacing between files
		echo -e "\n" >>"$concat_filepath"
	done

	# Read the concatenated content into memory
	concatenated_content=$(cat "$concat_filepath")
	status="$?"
	if [[ status -eq 0 ]]; then
		log_success "Concatenated ${#text_array[@]} files to $concat_filename"
		log_info "Total content length: ${#concatenated_content} characters"
		log_info "File saved at: $concat_filepath"
		# Reset
		CONCATENATED_CONTENT=""
		CONCATENATED_FILE_PATH=""
		# Export the content to a global variable for use elsewhere
		CONCATENATED_CONTENT="$concatenated_content"
		CONCATENATED_FILE_PATH="$concat_filepath"
		if [[ -n $CONCATENATED_CONTENT ]]; then
			log_info "Path $CONCATENATED_FILE_PATH"
		fi
	else
		log_error "Failed to read concatenated file into memory"
		return 1
	fi
}

# ================================================================================================
# MAIN EXECUTION
# ================================================================================================
main()
{
	if [[ ! -f $CONFIG_FILE ]]; then
		echo "Configuration file not found: $CONFIG_FILE"
		exit 1
	fi

	# Load configuration
	INPUT_DIR=$(helpers/get_config_helper.sh "paths.input_dir")
	OUTPUT_DIR=$(helpers/get_config_helper.sh "paths.output_dir")
	LOG_DIR=$(helpers/get_config_helper.sh "logs_dir.final_text_concat")
	PROCESSING_DIR=$(helpers/get_config_helper.sh "processing_dir.final_text_concat")

	# Reset directories

	mkdir -p "$LOG_DIR" "$PROCESSING_DIR"
	rm -rf "$PROCESSING_DIR" "$LOG_DIR"
	mkdir -p "$LOG_DIR" "$PROCESSING_DIR"
	LOG_FILE="$LOG_DIR/final_text_concat.log"
	touch "$LOG_FILE"
	log_info "RESETTING DIRS"
	# Set log file path

	log_info "$(date +%c) Final text concatenation start"

	declare -a pdf_array=()
	# Get all pdf files in INPUT_DIR (directory for pdf raw files)
	mapfile -t pdf_array < <(find "$INPUT_DIR" -type f -name "*.pdf" -exec basename {} .pdf \;)
	if [[ ${#pdf_array[@]} -eq 0 ]]; then
		log_error "No pdf files in input directory"
		exit 1
	else
		log_success "Found pdf for processing."
	fi

	# Confirm there are final_text directories
	if is_final_text_ready "${pdf_array[@]}"; then
		for final_text_path in "${FINAL_TEXT_DIRS_GLOBAL[@]}"; do
			log_info "PROCESSING $final_text_path"
			local safe_name
			local processing_dir_name
			processing_dir_name="$(get_last_two_dirs "$final_text_path")"
			safe_name=$(echo "$processing_dir_name" | tr '/' '_')
			processing_dir="${PROCESSING_DIR}/${safe_name}"
			rm -rf "${processing_dir}"*
			concat_file_dir="${OUTPUT_DIR}/$(basename "$(dirname "$final_text_path")")/concat"
			mkdir -p "$concat_file_dir"

			local temp_dir
			temp_dir=$(mktemp -d "${processing_dir}_XXXX")
			status="$?"
			if [[ status -ne 0 ]]; then
				log_error "Failed to create temporary directory"
				return 1
			fi

			create_single_file "$temp_dir" "$concat_file_dir" "$final_text_path"
		done
	fi

	exit 0
}

# Run main function
main "$@"
