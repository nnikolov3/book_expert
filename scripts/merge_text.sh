#!/bin/bash
# ================================================================================================
# Design: Niko Nikolov
# Code: Niko and LLMs

# Enable strict error handling - following guidelines
set -u

# ================================================================================================
# GLOBAL VARIABLES - All declared at top of script
# ================================================================================================
declare INPUT_DIR_GLOBAL=""
declare OUTPUT_DIR_GLOBAL=""
declare LOG_DIR_GLOBAL=""
declare PROCESSING_DIR_GLOBAL=""
declare LOG_FILE_GLOBAL=""
declare TEXT_TYPE_GLOBAL=""
declare -a TEXT_DIRS_GLOBAL=()
declare CONCATENATED_CONTENT_GLOBAL=""
declare CONCATENATED_FILE_PATH_GLOBAL=""

is_text_ready()
{
	# All local variables declared at top of function
	local -a pdf_array=("$@")
	local text_path=""
	local complete_path=""
	local complete_count=0
	local text_count=0
	local find_result=""
	local find_exit=""

	# Reset global array
	TEXT_DIRS_GLOBAL=()

	for pdf_name in "${pdf_array[@]}"; do
		log_info "Checking document: $pdf_name"
		text_path="$OUTPUT_DIR_GLOBAL/$pdf_name/$TEXT_TYPE_GLOBAL"
		complete_path="$OUTPUT_DIR_GLOBAL/$pdf_name/complete"

		if [[ -d $text_path ]]; then
			if [[ -d $complete_path ]]; then
				find_result=$(find "$complete_path" -type f 2>&1)
				find_exit="$?"
				if [[ $find_exit -eq 0 ]]; then
					complete_count=$(echo "$find_result" | wc -l)
					if [[ $complete_count -eq 1 ]]; then
						log_warn "$pdf_name has already a complete text file"
						log_info "If you want to generate a new file, remove the directory"
						continue
					fi
				fi
			fi

			find_result=$(find "$text_path" -type f 2>&1)
			find_exit="$?"
			if [[ $find_exit -eq 0 ]]; then
				text_count=$(echo "$find_result" | wc -l)
				if [[ $text_count -gt 0 ]]; then
					log_info "$TEXT_TYPE_GLOBAL files: $text_count"
					log_success "adding directory for processing"
					TEXT_DIRS_GLOBAL+=("$text_path")
				else
					log_info "$TEXT_TYPE_GLOBAL files: $text_count"
					log_warn "Review $text_path"
				fi
			else
				log_error "Failed to list files in $text_path: $find_result"
			fi
		else
			log_warn "Confirm path $text_path"
		fi
	done

	if [[ ${#TEXT_DIRS_GLOBAL[@]} -eq 0 ]]; then
		log_error "No directories to process with valid $TEXT_TYPE_GLOBAL files"
		return 1
	else
		log_success "Found directories to process"
		return 0
	fi
}

get_last_two_dirs()
{
	# All local variables declared at top of function
	local full_path="$1"
	local parent_dir=""
	local current_dir=""

	parent_dir=$(basename "$(dirname "$full_path")")
	current_dir=$(basename "$full_path")
	echo "$parent_dir/$current_dir"
}

create_single_file()
{
	# All local variables declared at top of function
	local processing_dir="$1"
	local complete_file_dir="$2"
	local text_path="$3"
	local rsync_result=""
	local rsync_exit=""
	local verify_result=""
	local verify_exit=""
	local -a text_array=()
	local number_files=0
	local complete_filename="complete.txt"
	local complete_filepath=""
	local concatenated_content=""
	local cat_exit=""
	local basename_file=""
	local cat_result=""

	# Input validation
	if [[ -z $processing_dir ]] || [[ ! -d $processing_dir ]]; then
		log_error "Invalid directory $processing_dir"
		return 1
	fi
	if [[ -z $text_path ]]; then
		log_error "Invalid directory for text"
		return 1
	fi
	if [[ -z $complete_file_dir ]] || [[ ! -d $complete_file_dir ]]; then
		log_error "Invalid directory for the complete file"
		return 1
	fi

	# Copy files with progress and error handling
	rsync_result=$(rsync -a "$text_path/" "$processing_dir/" 2>&1)
	rsync_exit="$?"

	if [[ $rsync_exit -ne 0 ]]; then
		log_error "Failed to copy files: $rsync_result"
		return 1
	fi

	# Verify copy integrity
	verify_result=$(rsync -a --checksum --dry-run "$text_path/" "$processing_dir/" 2>&1)
	verify_exit="$?"

	if [[ $verify_exit -eq 0 ]]; then
		if [[ -z $verify_result ]]; then
			log_success "STAGING COMPLETE"
		else
			log_warn "Files may differ:"
			log_info "$verify_result"
		fi
	else
		log_error "Failed to verify staging integrity"
		rm -rf "$processing_dir"
		return 1
	fi

	# Look for text files with various extensions
	mapfile -t text_array < <(find "$processing_dir" -type f -name "*.txt" | sort -V)
	number_files="${#text_array[@]}"

	if [[ $number_files -eq 0 ]]; then
		log_error "No TEXT files found in $processing_dir"
		log_info "DEBUG: Directory structure (first 5 files):"
		find "$processing_dir" -type f | head -5 | while read -r file; do
			log_info "$file"
		done
		return 1
	else
		log_success "Found ${#text_array[@]} text files. Continue Processing ..."
	fi

	complete_filepath="$complete_file_dir/$complete_filename"

	log_info "Starting file concatenation..."

	# Clear the output file
	if ! true >"$complete_filepath"; then
		log_error "Failed to create output file: $complete_filepath"
		return 1
	fi

	# Process each file in the sorted order
	for file in "${text_array[@]}"; do
		basename_file=$(basename "$file")
		log_info "Processing file: $basename_file"

		# Append file content
		cat_result=$(cat "$file" >>"$complete_filepath" 2>&1)
		cat_exit="$?"
		if [[ $cat_exit -eq 0 ]]; then
			log_success "Added $basename_file to complete file"
		else
			log_error "Failed to append $basename_file: $cat_result"
			return 1
		fi

		# Add spacing between files
		echo -e "\n" >>"$complete_filepath"
	done

	# Read the concatenated content into memory
	concatenated_content=$(cat "$complete_filepath" 2>&1)
	cat_exit="$?"

	if [[ $cat_exit -eq 0 ]]; then
		log_success "Concatenated ${#text_array[@]} files to $complete_filename"
		log_info "Total content length: ${#concatenated_content} characters"
		log_info "File saved at: $complete_filepath"

		# Reset global variables
		CONCATENATED_CONTENT_GLOBAL=""
		CONCATENATED_FILE_PATH_GLOBAL=""

		# Export the content to global variables for use elsewhere
		CONCATENATED_CONTENT_GLOBAL="$concatenated_content"
		CONCATENATED_FILE_PATH_GLOBAL="$complete_filepath"

		if [[ -n $CONCATENATED_CONTENT_GLOBAL ]]; then
			log_info "Path $CONCATENATED_FILE_PATH_GLOBAL"
		fi
	else
		log_error "Failed to read complete file into memory: $concatenated_content"
		return 1
	fi
}

# ================================================================================================
# MAIN EXECUTION
# ================================================================================================

main()
{
	# All local variables declared at top of function
	local logger="helpers/logging_utils_helper.sh"
	local -a pdf_array=()
	local find_result=""
	local find_exit=""
	local text_path=""
	local safe_name=""
	local processing_dir_name=""
	local processing_dir=""
	local complete_file_dir=""
	local temp_dir=""
	local mktemp_exit=""
	local mkdir_result=""
	local mkdir_exit=""
	local config_helper="helpers/get_config_helper.sh"

	# Load configuration directly like original - no unnecessary function
	INPUT_DIR_GLOBAL=$($config_helper "paths.input_dir")
	OUTPUT_DIR_GLOBAL=$($config_helper "paths.output_dir")
	LOG_DIR_GLOBAL=$($config_helper "logs_dir.narration_text_concat")
	PROCESSING_DIR_GLOBAL=$($config_helper "processing_dir.narration_text_concat")
	TEXT_TYPE_GLOBAL=$($config_helper "text_concatenation.text_type")

	# Default to final_text if not set
	if [[ -z $TEXT_TYPE_GLOBAL ]]; then
		TEXT_TYPE_GLOBAL="final_text"
	fi

	# Reset directories
	mkdir_result=$(mkdir -p "$LOG_DIR_GLOBAL" "$PROCESSING_DIR_GLOBAL" 2>&1)
	mkdir_exit="$?"
	if [[ $mkdir_exit -ne 0 ]]; then
		echo "Failed to create initial directories: $mkdir_result"
		return 1
	fi

	rm -rf "$PROCESSING_DIR_GLOBAL" "$LOG_DIR_GLOBAL"

	mkdir_result=$(mkdir -p "$LOG_DIR_GLOBAL" "$PROCESSING_DIR_GLOBAL" 2>&1)
	mkdir_exit="$?"
	if [[ $mkdir_exit -ne 0 ]]; then
		echo "Failed to recreate directories: $mkdir_result"
		return 1
	fi

	LOG_FILE_GLOBAL="$LOG_DIR_GLOBAL/narration_text_concat.log"
	if ! touch "$LOG_FILE_GLOBAL"; then
		echo "Failed to create log file"
		return 1
	fi

	if [[ ! -f $logger ]]; then
		echo "Logger helper not found: $logger"
		return 1
	fi

	# Source the logger
	source "$logger"

	log_info "RESETTING DIRS"
	log_info "$(date +%c) $TEXT_TYPE_GLOBAL to complete concatenation start"

	# Get all pdf files in INPUT_DIR_GLOBAL (directory for pdf raw files)
	find_result=$(find "$INPUT_DIR_GLOBAL" -type f -name "*.pdf" -exec basename {} .pdf \; 2>&1)
	find_exit="$?"

	if [[ $find_exit -ne 0 ]]; then
		log_error "Failed to find PDF files: $find_result"
		return 1
	fi

	mapfile -t pdf_array <<<"$find_result"

	if [[ ${#pdf_array[@]} -eq 0 ]]; then
		log_error "No pdf files in input directory"
		return 1
	else
		log_success "Found pdf files for processing."
	fi

	# Confirm there are text directories
	if is_text_ready "${pdf_array[@]}"; then
		for text_path in "${TEXT_DIRS_GLOBAL[@]}"; do
			log_info "PROCESSING $text_path"

			processing_dir_name=$(get_last_two_dirs "$text_path")
			safe_name=$(echo "$processing_dir_name" | tr '/' '_')
			processing_dir="${PROCESSING_DIR_GLOBAL}/${safe_name}"

			rm -rf "${processing_dir}"*

			complete_file_dir="${OUTPUT_DIR_GLOBAL}/$(basename "$(dirname "$text_path")")/complete"

			mkdir_result=$(mkdir -p "$complete_file_dir" 2>&1)
			mkdir_exit="$?"
			if [[ $mkdir_exit -ne 0 ]]; then
				log_error "Failed to create complete file directory: $mkdir_result"
				continue
			fi

			temp_dir=$(mktemp -d "${processing_dir}_XXXX" 2>&1)
			mktemp_exit="$?"

			if [[ $mktemp_exit -ne 0 ]]; then
				log_error "Failed to create temporary directory: $temp_dir"
				continue
			fi

			if create_single_file "$temp_dir" "$complete_file_dir" "$text_path"; then
				log_success "Successfully processed $text_path"
			else
				log_error "Failed to process $text_path"
			fi
		done
	else
		log_error "No text directories ready for processing"
		return 1
	fi

	return 0
}

# Run main function
main "$@"
