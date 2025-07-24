#!/bin/bash
# ================================================================================================
# Design: Niko Nikolov
# Code: Various LLMs
# ## Code Guidelines:
# - Declare variables before assignment to prevent undefined variable errors.
# - Use explicit if/then/fi blocks for readability.
# - Ensure all if/fi blocks are closed correctly
# - Use atomic file operations (mv, flock) to prevent race conditions in parallel processing.
# - Avoid mixing API calls.
# - Lint with shellcheck for portability and correctness.
# - Use grep -q for silent checks.
# - Check for unbound variables with set -u.
# - Clean up unused variables and maintain detailed comments.
# - Avoid unreachable code or redundant commands.
# - Keep code concise, clear, and self-documented.
# - Avoid 'useless cat' use cmd < file.
# - If not in a function use declare not local.
# - For Ghostscript use `ghostscript <cmd>`
# - Use `rsync` not cp
# - Initialize all variables
# - Code should be self documenting
# - Flows should have robust retry mechanisms
# - Prefer mapfile or read -a to split command outputs (or quote to avoid splitting)
# - Do not expand the code. Do more with less.
# - Follow bash best practices.
# - Avoid hardcoded values
# COMMENTS SHOULD NOT BE REMOVED, INCONCISTENCIES SHOULD BE UPDATED WHEN DETECTED
# USE MARKDOWN WITHIN THE COMMENT BLOCKS FOR COMMENTS
# ===============================================================================================

# Enable strict error handling
set -euo pipefail

# ================================================================================================
# CONFIGURATION AND GLOBAL VARIABLES
# ================================================================================================
declare -r CONFIG_FILE="project.toml"

# Global variables loaded from config
declare INPUT_DIR=""
declare OUTPUT_DIR=""
declare -a POLISHED_DIRS_GLOBAL=()
# Export the content to a global variable for use elsewhere
declare CONCATENATED_CONTENT=""
declare CONCATENATED_FILE_PATH=""

# ================================================================================================
# UTILITY FUNCTIONS
# ================================================================================================

# ## get_config()
# ## Purpose
# Loads configuration from `project.toml`.
# ## Parameters
# - $1: Configuration key to retrieve.
# ## Returns
# - The value of the key, or exits with error if missing.
get_config()
{
	local key="$1"
	local value
	value=$(yq -r ".${key} // \"\"" "$CONFIG_FILE" 2>/dev/null)
	if [[ -z $value ]]; then
		log_error "Missing required configuration key '$key' in $CONFIG_FILE"
		exit 1
	fi
	echo "$value"
}

# ================================================================================================
# MAIN PROCESSING FUNCTION
# ================================================================================================

print_line()
{
	echo "===================================================================="

}

is_polished_text()
{
	local -a pdf_array=("$@")
	local text_path
	local polished_path
	local concat_path
	local concat_count
	local text_count
	local polished_count
	POLISHED_DIRS_GLOBAL=()
	for pdf_name in "${pdf_array[@]}"; do
		echo "Checking document: $pdf_name"
		text_path="$OUTPUT_DIR/$pdf_name/text"
		polished_path="$OUTPUT_DIR/$pdf_name/polished"
		concat_path="$OUTPUT_DIR/$pdf_name/concat"
		if [[ -d $text_path && -d $polished_path ]]; then
			if [[ -d $concat_path ]]; then
				concat_count=$(find "$concat_path" -type f | wc -l)
				if [[ $concat_count -eq 1 ]]; then
					echo "WARN: $pdf_name has already a concatenated text"
					echo "INFO: If you want to generate a new file, remove the directory"
					print_line
					continue
				fi
			fi
			text_count=$(find "$text_path" -type f | wc -l)
			polished_count=$(find "$polished_path" -type f | wc -l)
			threshold=$(((text_count / 3) - 2))
			echo "THRESHOLD: $threshold"

			if [[ ($text_count -gt $polished_count) && $polished_count -gt 0 && $polished_count -gt $threshold ]]; then
				echo "INFO: TEXT: $text_count | POLISHED: $polished_count"
				echo "INFO: adding directory for processing"
				print_line
				POLISHED_DIRS_GLOBAL+=("$polished_path")
			else
				echo "INFO: TEXT: $text_count | POLISHED: $polished_count"
				echo "WARN: Review $polished_path"
				print_line
			fi
		else
			echo "WARN: Confirm paths $text_path and $text_path"
			print_line
		fi
	done

	if [ ${#POLISHED_DIRS_GLOBAL[@]} -eq 0 ]; then
		echo "ERROR: No directories to process with valid polished files"
		print_line
		exit 1
	else
		echo "SUCCESS: Found directories to process"
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
# create_single_file $processing_dir $concat_file_dir $polished_path
create_single_file()
{
	local processing_dir="$1"
	local concat_file_dir="$2"
	local polished_path="$3"

	# Input validation
	if [[ -z $processing_dir ]] || [[ ! -d $processing_dir ]]; then
		echo "ERROR: Invalid directory $processing_dir"
		return 1
	fi
	if [[ -z $polished_path ]]; then
		echo "ERROR: Invalid directory for polished text"
		return 1
	fi
	if [[ -z $concat_file_dir ]] || [[ ! -d $concat_file_dir ]]; then
		echo "ERROR: Invalid directory for the concatenated file"
		return 1
	fi

	# Copy files with progress and error handling
	rsync -a "$polished_path/" "$processing_dir/"

	# Verify copy integrity
	local rsync_output
	if rsync_output=$(rsync -a --checksum --dry-run "$polished_path/" "$processing_dir/"); then
		if [[ -z $rsync_output ]]; then
			echo "SUCCESS: STAGING COMPLETE"
			print_line
		else
			echo "WARNING: Files may differ:"
			echo "$rsync_output"
		fi
	else
		echo "ERROR: Failed to verify staging integrity"
		rm -rf "$processing_dir"
		return 1
	fi

	# Look for text files with various extensions
	declare -a text_array=()
	mapfile -t text_array < <(find "$processing_dir" -type f -name "*.txt" | sort -h)

	if [[ ${#text_array[@]} -eq 0 ]]; then
		echo "ERROR: No TEXT files found in $processing_dir"
		echo "DEBUG: Directory structure (first 5 files):"
		find "$processing_dir" -type f | head -5
		print_line
		return 1
	else
		echo "SUCCESS: Found ${#text_array[@]} text files. Continue Processing ..."
		print_line
	fi

	local concat_filename="concatenated.txt"
	local concat_filepath="$concat_file_dir/$concat_filename"
	local concatenated_content=""

	echo "INFO: Starting file concatenation..."

	# Clear the output file
	true >"$concat_filepath"

	# Process each file in the sorted order
	for file in "${text_array[@]}"; do
		local basename_file
		basename_file=$(basename "$file")
		echo "INFO: Processing file: $basename_file"

		# Append file content
		if cat "$file" >>"$concat_filepath"; then
			echo "SUCCESS: Added $basename_file to concatenated file"
			print_line
		else
			echo "ERROR: Failed to append $basename_file"
			return 1
		fi

		# Add spacing between files
		echo -e "\n" >>"$concat_filepath"
	done

	# Read the concatenated content into memory
	if concatenated_content=$(cat "$concat_filepath"); then
		echo "SUCCESS: Concatenated ${#text_array[@]} files to $concat_filename"
		echo "INFO: Total content length: ${#concatenated_content} characters"
		echo "INFO: File saved at: $concat_filepath"
		print_line
		# Reset
		CONCATENATED_CONTENT=""
		CONCATENATED_FILE_PATH=""
		# Export the content to a global variable for use elsewhere
		CONCATENATED_CONTENT="$concatenated_content"
		CONCATENATED_FILE_PATH="$concat_filepath"
		if [[ $CONCATENATED_CONTENT ]]; then
			echo "INFO: Path $CONCATENATED_FILE_PATH"
			print_line
		fi
	else
		echo "ERROR: Failed to read concatenated file into memory"
		print_line
		return 1
	fi
}

# ================================================================================================
# MAIN EXECUTION
# ================================================================================================
main()
{
	if [[ ! -f $CONFIG_FILE ]]; then
		log_error "Configuration file not found: $CONFIG_FILE"
		exit 1
	fi

	# Load configuration
	INPUT_DIR=$(get_config "paths.input_dir")
	OUTPUT_DIR=$(get_config "paths.output_dir")
	LOG_DIR=$(get_config "logs_dir.text_to_chunks")
	PROCESSING_DIR=$(get_config "processing_dir.text_to_chunks")

	# Reset directories
	echo "INFO: RESETTING DIRS"
	mkdir -p "$LOG_DIR" "$PROCESSING_DIR"
	rm -rf "$PROCESSING_DIR" "$LOG_DIR"
	mkdir -p "$LOG_DIR" "$PROCESSING_DIR"
	print_line
	echo "INFO: $(date +%c) Chunking text pages start"
	print_line

	declare -a pdf_array=()
	# Get all pdf files in INPUT_DIR (directory for pdf raw files)
	mapfile -t pdf_array < <(find "$INPUT_DIR" -type f -name "*.pdf" -exec basename {} .pdf \;)
	if [[ ${#pdf_array[@]} -eq 0 ]]; then
		echo "ERROR: No pdf files in input directory"
		print_line
		exit 1
	else
		echo "SUCCESS: Found pdf for processing."

	fi
	# Confirm there are polished directories
	if is_polished_text "${pdf_array[@]}"; then
		for polished_path in "${POLISHED_DIRS_GLOBAL[@]}"; do
			echo "INFO: PROCESSING $polished_path"
			local safe_name
			processing_dir="$(get_last_two_dirs "$polished_path")"
			safe_name=$(echo "$processing_dir" | tr '/' '_')
			processing_dir="${PROCESSING_DIR}/${safe_name}"
			rm -rf "${processing_dir}"*
			concat_file_dir="${OUTPUT_DIR}/$(basename "$(dirname "$polished_path")")/concat"
			tts_chunks_dir="${OUTPUT_DIR}/$(basename "$(dirname "$polished_path")")/tts_chunks"
			mkdir -p "$concat_file_dir"
			mkdir -p "$tts_chunks_dir"
			local temp_dir
			if ! temp_dir=$(mktemp -d "${processing_dir}_XXXX"); then
				echo "ERROR: Failed to create temporary directory"
				return 1
			fi
			create_single_file "$temp_dir" "$concat_file_dir" "$polished_path"

		done
	fi

	exit 0
}

# Run main function
main "$@"
