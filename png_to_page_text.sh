#!/usr/bin/env bash
# png_to_page_text.sh
# Design: Niko Nikolov
# Code: Various LLMs
# ## Code Guidelines:
# - Declare variables before assignment to prevent undefined variable errors.
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
# COMMENTS SHOULD NOT BE REMOVED, INCONSISTENCIES SHOULD BE UPDATED WHEN DETECTED
# USE MARKDOWN WITHIN THE COMMENT BLOCKS FOR COMMENTS
# ===============================================================================================
set -euo pipefail

# --- Configuration ---
CONFIG_FILE="$HOME/Dev/book_expert/project.toml"

# --- Global Variables ---
declare OUTPUT_DIR="" MAX_RETRIES=5 \
	NVIDIA_API_URL="" NVIDIA_API_KEY_VAR="" TEXT_FIX_MODEL="" CONCEPT_MODEL="" \
	LOG_DIR="" LOG_FILE="" GOOGLE_API_KEY_VAR="" POLISH_MODEL="" CURL_TIMEOUT=60 \
	PROCESSING_DIR="" INPUT_DIR="" API_RETRY_DELAY=60

# Helper functions that need to be defined elsewhere in your script
error()
{
	echo "ERROR: $1" >&2
}

log()
{
	echo "LOG: $1" >&2
}

print_line()
{
	echo "================================================================"
}

get_config()
{
	local key="$1"
	local value
	value=$(yq -r ".${key} // \"\"" "$CONFIG_FILE")
	if [[ -z $value ]]; then
		echo "Missing or empty configuration key $key in $CONFIG_FILE"
		return 1
	fi
	echo "$value"
	return 0
}

check_dependencies()
{
	local deps=("yq" "jq" "curl" "base64" "tesseract" "rsync" "mktemp" "nproc" "awk")
	for dep in "${deps[@]}"; do
		if ! command -v "$dep" >/dev/null; then
			echo "ERROR: '$dep' is not installed."
			exit 1
		fi
	done

	# Check if NVIDIA_API_KEY_VAR is set and then validate its value
	if [[ -z ${NVIDIA_API_KEY_VAR:-} ]]; then
		echo "ERROR: NVIDIA_API_KEY_VAR is not configured in $CONFIG_FILE."
		exit 1
	elif [[ -z ${!NVIDIA_API_KEY_VAR:-} ]]; then
		echo "ERROR: API key environment variable '$NVIDIA_API_KEY_VAR' is not set or is empty."
		exit 1
	fi

	# Check Google API key if using Google API
	if [[ -n ${GOOGLE_API_KEY_VAR:-} && -z ${!GOOGLE_API_KEY_VAR:-} ]]; then
		echo "ERROR: API key environment variable '$GOOGLE_API_KEY_VAR' is not set or is empty."
		exit 1
	fi

	# Validate other required variables
	if [[ -z ${TEXT_FIX_MODEL:-} ]]; then
		echo "ERROR: TEXT_FIX_MODEL is not set."
		exit 1
	fi

	if [[ -z ${CONCEPT_MODEL:-} ]]; then
		echo "ERROR: CONCEPT_MODEL is not set."
		exit 1
	fi

	echo "INFO: NO DEPENDENCY ISSUES"
	print_line
}

# Extract text from PNG using Google API
extract_text()
{
	local png_path="$1"
	local prompt temp_file response b64_temp_file

	# Create temporary files
	temp_file=$(mktemp) || {
		error "Failed to create temporary file"
		return 1
	}

	b64_temp_file=$(mktemp) || {
		error "Failed to create temporary file for base64 data"
		rm -f "$temp_file"
		return 1
	}

	# Ensure cleanup on exit
	trap 'rm -f "$temp_file" "$b64_temp_file"' RETURN

	# Encode PNG to base64 and save to temporary file
	if ! base64 -w 0 "$png_path" >"$b64_temp_file"; then
		error "Failed to encode PNG to base64"
		return 1
	fi

	prompt="GUIDELINES: You are a Ph.D STEM expert. You are provided a page to transcribe and extract the exact text from. 
    1. Avoid lists, headers, and emphasis like bold and italic, prefer plain paragraph text. 
    2. Describe any elements with words.  Example, 'List: *1. item*, 2.item' becomes 'the list has 2 items, the first item serves for the purpose ..' 
    3. Read verbatim the provided text, fixing grammar and formatting for clarity and readability. 
    4. Expand and explain technical terms, code blocks, data, jargon, and abbreviations to ensure accessibility for a Ph.D level audience.
    5. This is not an interactive chat; output must be standalone text without conversational elements like introductions or confirmations. 
    6. The text is a part of a larger collection, narrated via text-to-speech (TTS) for accessibility, requiring clear and natural flow. 
    7. Do not include notes, feedback, or confirmations in the output, as they disrupt the narration flow. 
    8. Provide only the extracted and formatted text, suitable for TTS narration.
    9. The technical description should allow for the listener to envision the description."

	# Create Google API payload by building JSON in parts to avoid argument limits
	{
		echo '{"contents":[{"parts":['
		printf '{"text":%s},' "$(echo "$prompt" | jq -R -s .)"
		printf '{"inline_data":{"mime_type":"image/png","data":%s}}' "$(jq -R -s . <"$b64_temp_file")"
		echo ']}]}'
	} >"$temp_file"

	# Validate JSON
	if ! jq . "$temp_file" >/dev/null 2>&1; then
		error "Invalid JSON payload created"
		return 1
	fi

	# Google API call with retry logic
	for ((attempt = 1; attempt <= MAX_RETRIES; attempt++)); do

		response=$(curl --fail --silent --show-error \
			-H "x-goog-api-key: ${!GOOGLE_API_KEY_VAR}" \
			-H "Content-Type: application/json" \
			-X POST --data-binary "@$temp_file" \
			--max-time "$CURL_TIMEOUT" \
			"https://generativelanguage.googleapis.com/v1beta/models/$POLISH_MODEL:generateContent" 2>>"$LOG_FILE")

		local http_code=$?

		# Check for successful response
		if [[ $http_code -eq 0 && -n $response ]]; then
			# Extract response content
			local extracted_response
			extracted_response=$(echo "$response" | jq -r '.candidates[0].content.parts[0].text // empty')

			if [[ -n $extracted_response && $extracted_response != "null" ]]; then
				echo "$extracted_response"
				return 0
			else
				log "Empty or null response from Google API (attempt $attempt/$MAX_RETRIES)"
			fi
		else
			log "Google API call failed (attempt $attempt/$MAX_RETRIES)"
		fi

		# Don't sleep after the last attempt
		if [[ $attempt -lt $MAX_RETRIES ]]; then
			log "Waiting ${API_RETRY_DELAY}s before retry..."
			sleep "$API_RETRY_DELAY"
		fi
	done

	error "Google API call failed after $MAX_RETRIES attempts"
	print_line
	return 1
}

# Extract concepts from PNG using NVIDIA API
extract_concepts()
{
	local png_path="$1"
	local temp_file response b64_temp_file

	# Create temporary files for JSON payload and base64 data
	temp_file=$(mktemp) || {
		error "Failed to create temporary file"
		return 1
	}

	b64_temp_file=$(mktemp) || {
		error "Failed to create temporary file for base64 data"
		rm -f "$temp_file"
		return 1
	}

	# Ensure cleanup on exit
	trap 'rm -f "$temp_file" "$b64_temp_file"' RETURN

	# Check file size before processing
	local file_size
	file_size=$(stat -f%z "$png_path" 2>/dev/null || stat -c%s "$png_path" 2>/dev/null || echo "0")
	if [[ $file_size -gt 5000000 ]]; then # 5MB limit
		error "PNG file too large for processing: ${file_size} bytes"
		return 1
	fi

	# Encode PNG to base64 and save to temporary file
	if ! base64 -w 0 "$png_path" >"$b64_temp_file"; then
		error "Failed to encode PNG to base64"
		return 1
	fi

	local prompt="GUIDELINES:
    1. You are a STEM professor with deep expertise in technical domains. 
    2. Identify and explain the concepts and technical information from a page of a technical document, focusing on clarity and insight. 
    3. Grapnhs, code, formula, assembly code, write as if contributing to a technical book, in an engaging, accessible style for a Ph.D student. 
    4. This is not an interactive chat; output must exclude conversational elements like introductions or summaries. 
    5. The text will be part of a larger collection, narrated via TTS for accessibility, requiring clear and natural flow. 
    6. Ensure explanations are insightful, correct, deep, and reflecting a thorough understanding of the concepts for educational value. 
    7. Avoid summaries, conclusions, or introductions to ensure seamless integration into the collection.  
    8. Do not reference 'text', 'page', 'image', or 'picture'; focus directly on the concepts as the main subject. 
    9. Start with the concepts as the primary focus for narrative coherence. Explain them educationally adding verbal emphasis, context, examples, analogies.
    10. This is not a summarization task. Do not provide summary. 
    11. Your response should not have any lists, emphasis, bold or italic, instead describe these elements or structure the text implicitly to convey it.
    12. Graphs and graphical content should be narrated, such as 'In the table, the x and y axis.."

	# Create NVIDIA API payload by building JSON in parts to avoid argument limits
	{
		printf '{"model":%s,' "$(echo "$CONCEPT_MODEL" | jq -R .)"
		echo '"messages":[{"role":"user","content":['
		printf '{"type":"text","text":%s},' "$(echo "$prompt" | jq -R -s .)"
		printf '{"type":"image_url","image_url":{"url":%s}}' "$(printf "data:image/png;base64,%s" "$(cat "$b64_temp_file")" | jq -R .)"
		echo ']}],'
		echo '"max_tokens":8192,'
		echo '"temperature":0.5,'
		echo '"top_p":0.5,'
		echo '"stream":false}'
	} >"$temp_file"

	# Validate JSON
	if ! jq . "$temp_file" >/dev/null 2>&1; then
		error "Invalid JSON payload created for concept extraction"
		return 1
	fi

	# NVIDIA API call with retry logic
	for ((attempt = 1; attempt <= MAX_RETRIES; attempt++)); do
		log "NVIDIA: API call attempt $attempt/$MAX_RETRIES"

		response=$(curl -sS --request POST \
			--url "$NVIDIA_API_URL" \
			--header "Authorization: Bearer ${!NVIDIA_API_KEY_VAR}" \
			--header "Content-Type: application/json" \
			--data-binary "@$temp_file" \
			--connect-timeout 30 \
			--max-time 60 \
			2>>"$LOG_FILE")

		local http_code=$?

		# Check for successful response
		if [[ $http_code -eq 0 && -n $response ]]; then
			# Check if it's valid JSON with error
			if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
				local error_msg
				error_msg=$(echo "$response" | jq -r '.error.message // .error // "Unknown API error"')
				log "API returned error in response: $error_msg (attempt $attempt/$MAX_RETRIES)"
			else
				# Success - extract and return response directly
				local extracted_response
				extracted_response=$(echo "$response" | jq -r '.choices[0].message.content // empty')
				if [[ -n $extracted_response && $extracted_response != "null" ]]; then
					echo "$extracted_response"
					return 0
				else
					log "Empty or null response content (attempt $attempt/$MAX_RETRIES)"
				fi
			fi
		else
			log "API call failed (attempt $attempt/$MAX_RETRIES)"
		fi

		# Don't sleep after the last attempt
		if [[ $attempt -lt $MAX_RETRIES ]]; then
			log "Waiting ${API_RETRY_DELAY}s before retry..."
			sleep "$API_RETRY_DELAY"
		fi
	done

	error "API call failed after $MAX_RETRIES attempts"
	return 1
}

# Process a single PNG file with retry logic
process_single_png()
{
	local png="$1"
	local storage_dir="$2"
	local max_retries="$MAX_RETRIES"
	local retries=0
	local base_name
	base_name=$(basename "$png" .png)
	local output_file="$storage_dir/${base_name}.txt"

	# Ensure storage directory exists
	mkdir -p "$storage_dir"

	while [[ $retries -lt $max_retries ]]; do
		echo "Processing: $png (attempt $((retries + 1))/$max_retries)"

		# Extract text from the PNG
		if extracted_text=$(extract_text "$png"); then
			echo "Text extraction completed for: $png"
			# Save extracted text to file
			echo "$extracted_text" >"$output_file"
			echo "Text saved to: '$output_file'"

			echo "Starting concept extraction for: $png"
			if concepts=$(extract_concepts "$png"); then
				echo "Concept extraction completed for: $png"
				# Append concepts to the same file
				echo "$concepts" >>"$output_file"
				echo "Concepts saved to: '$output_file'"
				echo "SUCCESS: $output_file"
				print_line
				return 0
			else
				echo "Concept extraction failed for: $png" >&2
				echo "ERROR: $output_file"
				return 1
			fi
		else
			echo "Text extraction failed for: $png" >&2
			((retries++))
			if [[ $retries -lt $max_retries ]]; then
				echo "INFO: RETRYING $png (attempt $((retries + 1))/$max_retries)"
				sleep "$API_RETRY_DELAY"
			fi
		fi
		echo "SUCCESS: $png"
		print_line
	done

	echo "ERROR: Failed to process $png after $max_retries retries"
	return 1
}

# Process multiple PNG files
process_pngs()
{
	local -a png_files=("$@")
	local storage_dir="${png_files[-1]}" # Last argument is storage_dir
	unset 'png_files[-1]'                # Remove storage_dir from array

	for png in "${png_files[@]}"; do
		if ! process_single_png "$png" "$storage_dir"; then
			echo "ERROR: Failed to process $png"
			print_line
		fi
	done

	echo "All processing complete."
}

pre_process_png()
{
	local png_directory="$1"
	local processing_png_dir="$2"
	local storage_dir="$3"

	# Ensure processing directory exists
	mkdir -p "$PROCESSING_DIR"
	mkdir -p "$storage_dir"

	echo "STORAGE: $storage_dir"
	# Create safe temp directory name
	local safe_name
	safe_name=$(echo "$processing_png_dir" | tr '/' '_') # extensible_firmware_png
	echo "INFO: Removing old directories with the same base directory"
	rm -rf "$PROCESSING_DIR/${safe_name}"_*
	temp_dir=$(mktemp -d "$PROCESSING_DIR/${safe_name}_XXXXXX")

	echo "STAGING TO NEW PROCESSING DIR: $temp_dir"
	print_line
	rsync -a --info=progress2 "$png_directory/" "$temp_dir/"

	# Silent verification
	output=$(rsync -a --checksum --dry-run "$png_directory/" "$temp_dir/" 2>/dev/null)
	if [[ -z $output ]]; then
		echo "SUCCESS: STAGING COMPLETE"
	else
		echo "ERROR: Files differ:"
		echo "$output"
	fi

	declare -a png_array=()
	mapfile -t png_array < <(find "$temp_dir" -type f -name "*.png" | sort -h)

	if [ ${#png_array[@]} -eq 0 ]; then
		echo "ERROR: No png files? This is odd."
		print_line
		return 1
	else
		echo "SUCCESS: Found pngs. Processing ..."

		print_line

		if process_pngs "${png_array[@]}" "$storage_dir"; then
			echo "SUCCESS: PNG processing completed successfully for $temp_dir"
		else
			echo "ERROR: PNG processing failed"
			return 1
		fi
	fi

}

declare -a PNG_DIRS_GLOBAL=()
are_png_in_dirs()
{
	local -a pdf_array=("$@")
	PNG_DIRS_GLOBAL=() # Reset global array
	local dir_path
	local text_path
	local png_count
	local text_count
	for pdf_name in "${pdf_array[@]}"; do
		echo "Checking document: $pdf_name"
		dir_path="$OUTPUT_DIR/$pdf_name/png"
		text_path="$OUTPUT_DIR/$pdf_name/text"
		if [[ -d $text_path ]]; then
			text_count=$(find "$text_path" -type f | wc -l)
		fi
		if [ -d "$dir_path" ]; then
			png_count=$(find "$dir_path" -type f | wc -l)
			if [[ ($png_count -eq $text_count) && ($text_count -gt 0) ]]; then
				echo "WARN: REVIEW $text_path, there are text files."
				echo "INFO: Remove the directory if you want to generate the text"
				print_line
			elif [ "$png_count" -gt 0 ]; then
				echo "$dir_path exists and contains $png_count file(s)"
				PNG_DIRS_GLOBAL+=("$dir_path")
				print_line
			else
				echo "$dir_path exists but is empty"
				print_line
			fi
		else
			echo "$dir_path does not exist"
			print_line
		fi
	done

	if [ ${#PNG_DIRS_GLOBAL[@]} -eq 0 ]; then
		echo "ERROR: No directories with png with valid png"
		print_line
		return 1
	else
		echo "SUCCESS: Found directories to process"
		print_line
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
	declare date_time
	date_time=$(date +%c)
	echo "START CONVERSION: $date_time"
	print_line
	# Load configuration with validation
	echo "Loading configurations"
	print_line
	INPUT_DIR=$(get_config "paths.input_dir")
	OUTPUT_DIR=$(get_config "paths.output_dir")
	NVIDIA_API_URL=$(get_config "nvidia_api.url")
	NVIDIA_API_KEY_VAR=$(get_config "nvidia_api.api_key_variable")
	TEXT_FIX_MODEL=$(get_config "nvidia_api.text_fix_model")
	CONCEPT_MODEL=$(get_config "nvidia_api.concept_model")
	LOG_DIR=$(get_config "logs_dir.png_to_text")
	PROCESSING_DIR=$(get_config "processing_dir.png_to_text")
	MAX_RETRIES=$(get_config "retry.max_retries")
	API_RETRY_DELAY=$(get_config "retry.retry_delay_seconds")

	# Load Google API configuration (if available)
	GOOGLE_API_KEY_VAR=$(get_config "google_api.api_key_variable" 2>/dev/null || true)
	POLISH_MODEL=$(get_config "google_api.polish_model" 2>/dev/null || true)

	mkdir -p "$PROCESSING_DIR"
	mkdir -p "$LOG_DIR" || {
		echo "Failed to create log directory: $LOG_DIR"
		exit 1
	}
	LOG_FILE="$LOG_DIR/log_$(date +'%Y%m%d_%H%M%S').log"
	touch "$LOG_FILE" || {
		echo "Failed to create log file."
		exit 1
	}
	echo "Script started. Log file: $LOG_FILE"
	echo "Checking dependencies"
	check_dependencies

	declare -a pdf_array=()
	# Get all pdf files in INPUT_DIR (directory for pdf raw files)
	mapfile -t pdf_array < <(find "$INPUT_DIR" -type f -name "*.pdf" -exec basename {} .pdf \;)
	if [ ${#pdf_array[@]} -eq 0 ]; then
		echo "No pdf files in input directory"
		exit 1
	else
		echo "Found pdf for processing. Checking for valid png .."
	fi
	print_line

	if are_png_in_dirs "${pdf_array[@]}"; then
		# Process png
		for png_path in "${PNG_DIRS_GLOBAL[@]}"; do
			printf "PROCESSING: %s\n" "$png_path"
			staging_dir_name=$(get_last_two_dirs "$png_path")
			parent_dir=$OUTPUT_DIR/$(basename "$(dirname "$png_path")")/text
			pre_process_png "$png_path" "$staging_dir_name" "$parent_dir"
			print_line
		done
	fi

	log "All processing jobs completed."
	return 0
}

# Entry point for the script
main "$@"
