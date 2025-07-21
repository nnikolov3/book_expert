#!/usr/bin/env bash
# polish_pdf_text.sh - Serial text polishing system using Gemini API
# Combines sequential pages (1+2+3, 4+5+6, etc.) into polished text files
# Validates text directory by comparing with PNG directory
# Processes incomplete directories with proper retry logic

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
# COMMENTS SHOULD NOT BE REMOVED, INCONCISTENCIES SHOULD BE UPDATED WHEN DETECTED
# USE MARKDOWN WITHIN THE COMMENT BLOCKS FOR COMMENTS
# ===============================================================================================
set -euo pipefail

# --- Configuration ---
CONFIG_FILE="$HOME/Dev/book_expert/project.toml"
CURL_TIMEOUT=120

# --- Global Variables ---
declare OUTPUT_DIR="" PROCESSING_DIR="" \
	GEMINI_API_KEY_VAR="" POLISH_MODEL="" \
	LOG_DIR="" LOG_FILE="" INPUT_DIR="" TEXT_DIRS_GLOBAL="" \
	FAILED_LOG="" MAX_API_RETRIES=0 RETRY_DELAY_SECONDS=0

declare -a RESULT_ARRAY=()

print_line()
{
	echo "======================================================================="
}
get_config()
{
	local key="$1"
	local default_value="${2:-}"
	local value
	value=$(yq -r ".${key} // \"\"" "$CONFIG_FILE") || {
		[[ -n $default_value ]] && {
			echo "$default_value"
			return 0
		}
		log "Failed to read configuration key '$key' from $CONFIG_FILE"
		return 1
	}
	[[ -z $value && -n $default_value ]] && {
		echo "$default_value"
		return 0
	}
	[[ -z $value ]] && {
		log "Missing required configuration key '$key' in $CONFIG_FILE"
		return 1
	}
	echo "$value"
}

log()
{
	echo "LOG: $1" >&2
}

check_dependencies()
{
	local deps=("yq" "jq" "curl" "rsync" "mktemp")
	for dep in "${deps[@]}"; do
		command -v "$dep" >/dev/null || {
			echo "Dependency '$dep' is not installed."
			exit 1
		}
	done

	[[ -z ${GEMINI_API_KEY_VAR:-} ]] && {
		echo "GEMINI_API_KEY_VAR not configured"
		exit 1
	}
	[[ -z ${!GEMINI_API_KEY_VAR:-} ]] && {
		echo "API key variable '$GEMINI_API_KEY_VAR' not set"
		exit 1
	}

	[[ -z ${POLISH_MODEL:-} ]] && {
		echo "POLISH_MODEL not set"
		exit 1
	}
	echo "SUCCESS: Dependencies verified"
	print_line
	return 0
}

call_api_gemini()
{
	local payload_file="$1"
	local response_file
	response_file=$(mktemp -p "$PROCESSING_DIR" "api_response.XXXXXX")

	local curl_error_file
	curl_error_file=$(mktemp -p "$PROCESSING_DIR" "curl_error.XXXXXX")

	local http_code
	http_code=$(curl --fail --silent --show-error -w "%{http_code}" -o "$response_file" \
		--request POST \
		--url "https://generativelanguage.googleapis.com/v1beta/models/${POLISH_MODEL}:generateContent" \
		-H "x-goog-api-key: ${!GEMINI_API_KEY_VAR}" \
		-H "Content-Type: application/json" \
		-d @"$payload_file" \
		--max-time "$CURL_TIMEOUT" \
		2>"$curl_error_file") || true

	if [[ $http_code -ne 200 || ! -s $response_file ]]; then
		log "Gemini API call failed with HTTP code: $http_code"
		log "Curl error: $(cat "$curl_error_file")"
		log "Response file content: $(cat "$response_file")"
		rm -f "$response_file" "$curl_error_file"
		return 1
	fi
	rm -f "$curl_error_file"

	local content
	content=$(jq -r '.candidates[0].content.parts[0].text // empty' "$response_file" 2>/dev/null)
	if [[ -z $content || $content == "null" ]]; then
		log "Failed to extract content from Gemini API response"
		log "Full API response: $(cat "$response_file")"
		rm -f "$response_file"
		return 1
	fi

	echo "$content" >"$response_file"
	echo "$response_file"
}

process_text_group()
{
	local first_file="$1"
	local second_file="$2"
	local third_file="$3"
	local output_index="$4"
	local storage_dir="$5"

	# Build file description
	local desc="$first_file"
	local polished_file
	polished_file="polished_${output_index}.txt"

	[[ -n $second_file && $second_file != "" ]] && desc="$desc + $(basename "$second_file")"
	[[ -n $third_file && $third_file != "" ]] && desc="$desc + $(basename "$third_file")"
	log "Processing: $desc -> $polished_file"

	# Combine text files
	local combined_text
	combined_text=$(cat "$first_file")
	[[ -n $second_file && $second_file != "" ]] && combined_text="$combined_text\n\n$(cat "$second_file")"
	[[ -n $third_file && $third_file != "" ]] && combined_text="$combined_text\n\n$(cat "$third_file")"

	local prompt="GUIDELINES: You are an expert Ph.D STEM technical editor and educator, and writing specialist. 
    1. Polish and refine the provided text for clarity, coherence, and professional presentation. 
    2. Maintain all technical accuracy while improving readability and flow. 
    3. Ensure the text flows naturally and is suitable for text-to-speech (TTS) narration. 
    4. Fix any grammatical errors, awkward phrasing, or unclear expressions. 
    5. Enhance transitions between concepts and improve overall narrative structure. 
    6. Maintain the technical depth and educational value of the content. 
    7. This is not an interactive chat; output must be standalone polished text without conversational elements such as confirming the request. 
    8. The text will be part of a larger technical collection, so ensure consistency in style and tone. 
    9. Focus on creating engaging, accessible content for a Ph.D level technical audience. 
    10. Remove any artifacts, redundancies, or formatting issues that would disrupt TTS narration. 
    11. Provide only the polished and refined text, ready for final use.
    12. No chapter, page numbers or other invalid artifacts. 
    13. Start and focus on the concepts as the main point. 
    14. This is not a summarization task, do not summarize the content.  
    15. This is a educational content. 
    16. You can add analogies, examples, and further the explanation to promote learning.  
    17. Do not dumb down the content. 
    18. Maintain TTS narration flow.  
    19. Write everything in plain text paragraphs, no emphasis, headers, bold, italic, no conversational elements.  
    20. Code, graphs, diagrams and similar, should be described word for word as being explained to someone who can't seem them.  
    21. If anything needs emphasizing, describe it via words. 
    22. Avoid using directrly technical examples, formulas, assembly instructions, instead describe it in words.
    Example, 'E=mc^2', 'Energy is equal to mass and speed of light squared.', '1 + 1 = 2', one plus one equals two. There should no special characters in the response. For code, if '(a > 0){ printf(\"Hello\")}', 'the C code checks if a is larger than zero, if it is larger, then it prints Hello'
    23. If there are problems (textbook type problems ) solve them, explain the solution. 

    TEXT TO POLISH AND RETURN ONLY THE POLISHED TEXT: $combined_text"

	local payload_file
	payload_file=$(mktemp -p "$PROCESSING_DIR" "api_payload.XXXXXX")
	jq -n --arg prompt "$prompt" \
		'{ "contents": [{ "parts": [{ "text": $prompt }] }] }' >"$payload_file"

	# Retry logic for API calls
	local retry_count=0
	local api_response_file=""

	while [[ $retry_count -lt $MAX_API_RETRIES ]]; do
		if api_response_file=$(call_api_gemini "$payload_file"); then
			break
		fi
		((retry_count++))
		[[ $retry_count -lt $MAX_API_RETRIES ]] && {
			log "API retry $retry_count/$MAX_API_RETRIES for $polished_file"
			sleep "$RETRY_DELAY_SECONDS"
		}
	done

	rm -f "$payload_file"

	if [[ -z $api_response_file ]]; then
		log "ERROR: API call failed after $MAX_API_RETRIES retries for $polished_file"
		return 1
	fi

	# Read the polished content from the API response file
	local polished_text
	polished_text=$(cat "$api_response_file")
	rm -f "$api_response_file"

	if [[ -z $polished_text ]]; then
		log "ERROR: Empty polished text received for $polished_file"
		return 1
	fi

	# Save the polished text to the output file
	local output_file_path="${storage_dir}/${polished_file}"
	if echo "$polished_text" >"$output_file_path"; then
		echo "SUCCESS: Saved $output_file_path"
		print_line
		return 0
	else
		log "ERROR: Failed to save polished text to $output_file_path"
		return 1
	fi
}

polish_text()
{
	local storage_dir="$1"

	local total_files=${#RESULT_ARRAY[@]}
	local output_index=0

	if [[ $total_files -eq 0 ]]; then
		log "No text files to process"
		return 1
	fi

	log "Processing $total_files text files in groups of 3"
	print_line
	# Process files in groups of 3
	for ((i = 0; i < total_files; i += 3)); do
		local first_file="${RESULT_ARRAY[i]}"
		local second_file=""
		local third_file=""

		# Check if files exist and are readable
		if [[ ! -r $first_file ]]; then
			log "ERROR: Cannot read file: $first_file"
			return 1
		fi

		# Check if second file exists
		if [[ $((i + 1)) -lt $total_files ]]; then
			local candidate="${RESULT_ARRAY[$((i + 1))]}"
			if [[ -r $candidate ]]; then
				second_file="$candidate"
			fi
		fi

		# Check if third file exists
		if [[ $((i + 2)) -lt $total_files ]]; then
			local candidate="${RESULT_ARRAY[$((i + 2))]}"
			if [[ -r $candidate ]]; then
				third_file="$candidate"
			fi
		fi

		local end_file=$((i + 3 <= total_files ? i + 3 : total_files))
		log "Processing group $output_index: files $((i + 1))-$end_file of $total_files"
		print_line
		# Call existing process_text_group function
		if process_text_group "$first_file" "$second_file" "$third_file" "$output_index" "$storage_dir"; then
			echo "SUCCESS: Processed polished_'$output_index"
			print_line
		else
			echo "WARN: Failed to process group $output_index"

		fi
		output_index=$((output_index + 1))
	done

	print_line
	return 0
}

pre_process_text()
{
	local text_directory="$1"
	local processing_text_dir="$2"
	local storage_dir="$3"
	# Reset
	RESULT_ARRAY=()

	# Input validation
	if [[ -z $text_directory ]] || [[ ! -d $text_directory ]]; then
		echo "ERROR: Invalid text directory: $text_directory"
		return 1
	fi

	if [[ -z $processing_text_dir ]]; then
		echo "ERROR: Processing text directory not specified"
		return 1
	fi

	if [[ -z $storage_dir ]] || [[ ! -d $storage_dir ]]; then
		echo "ERROR: Invalid storage directory: $storage_dir"
		return 1
	fi

	# Check if PROCESSING_DIR is defined
	if [[ -z $PROCESSING_DIR ]]; then
		echo "ERROR: PROCESSING_DIR environment variable not set"
		return 1
	fi

	echo "INFO: STORAGE $storage_dir"
	print_line

	# Create safe directory name
	local safe_name
	safe_name=$(echo "$processing_text_dir" | tr '/' '_')

	echo "INFO: Removing old directories with the same base directory"
	rm -rf "${PROCESSING_DIR:?}/${safe_name}"_*

	# Create temporary directory with error handling
	local temp_dir
	if ! temp_dir=$(mktemp -d "$PROCESSING_DIR/${safe_name}_XXXX"); then
		echo "ERROR: Failed to create temporary directory"
		return 1
	fi

	echo "STAGING TO PROCESSING DIR: $temp_dir"
	print_line

	# Copy files with progress and error handling
	rsync -a "$text_directory/" "$temp_dir/"

	# Verify copy integrity
	local rsync_output
	if rsync_output=$(rsync -a --checksum --dry-run "$text_directory/" "$temp_dir/"); then
		if [[ -z $rsync_output ]]; then
			echo "SUCCESS: STAGING COMPLETE"
			print_line
		else
			echo "WARNING: Files may differ:"
			echo "$rsync_output"
		fi
	else
		echo "ERROR: Failed to verify staging integrity"
		rm -rf "$temp_dir"
		return 1
	fi

	# Look for text files with various extensions
	declare -a text_array=()
	mapfile -t text_array < <(find "$temp_dir" -type f -name "*.txt" | sort -h)
	if [[ ${#text_array[@]} -eq 0 ]]; then
		echo "ERROR: No TEXT files found in $temp_dir"
		echo "DEBUG: Directory structure (first 5 files):"
		find "$temp_dir" -type f | head -5
		print_line
		rm -rf "$temp_dir" # Cleanup on failure
		return 1
	else
		echo "SUCCESS: Found ${#text_array[@]} text files. Continue Processing ..."
		print_line
		# Copy array to the reference
		RESULT_ARRAY=("${text_array[@]}")
	fi

}
are_png_and_text()
{
	local -a pdf_array=("$@")
	TEXT_DIRS_GLOBAL=() # Reset global directory
	for pdf_name in "${pdf_array[@]}"; do
		echo "Checking document: $pdf_name"
		png_path="$OUTPUT_DIR/$pdf_name/png"
		text_path="$OUTPUT_DIR/$pdf_name/text"
		polished_path="$OUTPUT_DIR/$pdf_name/polished"
		if [[ -d $polished_path ]]; then
			polished_count=$(find "$polished_path" -type f | wc -l)
			if [[ $polished_count -gt 0 ]]; then
				echo "WARN: There is an existing directory with polished text"
				echo "INFO: Erase the directory if you want to generate new text"
				continue
			fi
		fi
		if [[ -d $png_path && -d $text_path ]]; then
			png_count=$(find "$png_path" -type f | wc -l)
			text_count=$(find "$text_path" -type f | wc -l)
			if [[ $text_count -gt 0 && $text_count -eq $png_count ]]; then
				echo "INFO: PNG: $png_count | TEXT: $text_count"
				echo "INFO: adding directory for processing"
				print_line
				TEXT_DIRS_GLOBAL+=("$text_path")
			else
				echo "INFO: TEXT and PNG do not match"
				echo "WARN: Review $text_path"
				print_line
			fi
		else
			echo "WARN: Confirm paths $png_path and $text_path"
			print_line
		fi
	done

	if [ ${#TEXT_DIRS_GLOBAL[@]} -eq 0 ]; then
		echo "ERROR: No directories to process with valid png and text"
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

main()
{
	# Load configuration
	INPUT_DIR=$(get_config "paths.input_dir")
	OUTPUT_DIR=$(get_config "paths.output_dir")
	PROCESSING_DIR=$(get_config "processing_dir.polish_text")
	GEMINI_API_KEY_VAR=$(get_config "google_api.api_key_variable")
	POLISH_MODEL=$(get_config "google_api.polish_model")
	LOG_DIR=$(get_config "logs_dir.polish_text")
	MAX_API_RETRIES=$(get_config "retry.max_retries" "5")
	RETRY_DELAY_SECONDS=$(get_config "retry.retry_delay_seconds" "5")
	FAILED_LOG="$LOG_DIR/failed_pages.log"

	# Reset directories
	echo "INFO: RESETTING DIRS"
	mkdir -p "$LOG_DIR" "$PROCESSING_DIR"
	rm -rf "$PROCESSING_DIR" "$LOG_DIR"
	mkdir -p "$LOG_DIR" "$PROCESSING_DIR"

	LOG_FILE="$LOG_DIR/log_$(date +'%Y%m%d_%H%M%S').log"
	touch "$LOG_FILE" "$FAILED_LOG"
	echo "Script started. Log file: $LOG_FILE"

	check_dependencies
	declare -a pdf_array=()
	# Get all pdf files in INPUT_DIR (directory for pdf raw files)
	mapfile -t pdf_array < <(find "$INPUT_DIR" -type f -name "*.pdf" -exec basename {} .pdf \;)
	if [[ ${#pdf_array[@]} -eq 0 ]]; then
		echo "No pdf files in input directory"
		exit 1
	else
		echo "Found pdf for processing."
	fi
	print_line

	# Confirm we have text to process
	# Text should have the same number of files as png
	if are_png_and_text "${pdf_array[@]}"; then
		for text_path in "${TEXT_DIRS_GLOBAL[@]}"; do
			echo "PROCESSING: $text_path"
			staging_dir_name=$(get_last_two_dirs "$text_path")
			storage_dir="${OUTPUT_DIR}/$(basename "$(dirname "$text_path")")/polished"
			mkdir -p "$storage_dir"

			if pre_process_text "$text_path" "$staging_dir_name" "$storage_dir"; then
				echo "INFO: Captured ${#RESULT_ARRAY[@]} files:"
				print_line
				polish_text "$storage_dir"

			fi
		done

	fi

	log "All processing completed successfully"
	return 0
}

main "$@"
