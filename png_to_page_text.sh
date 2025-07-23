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
# - DO NOT USE if <cmd>; then. Rather, use output=$(cmd) if $output; then
# - DO NOT USE  2>>"$LOG_FILE"
# - DO NOT USE ((i++)) instead use i=$((i + 1))
# - DO NOT IGNORE the guidelines
# - AVOID Redirections 2>/dev/null
# - Declare / assign each variable on its own line
# COMMENTS SHOULD NOT BE REMOVED, INCONSISTENCIES SHOULD BE UPDATED WHEN DETECTED
# USE MARKDOWN WITHIN THE COMMENT BLOCKS FOR COMMENTS
# ===============================================================================================
#
# TODO:
set -euo pipefail
# Signal handling for graceful shutdown
cleanup_on_exit()
{
	local exit_code
	exit_code=$?
	echo "Script interrupted or exiting with code $exit_code"

	# Clean up any temp directories if they exist
	if [[ -n ${PROCESSING_DIR:-} ]]; then
		echo "Cleaning up processing directories..."
		find "$PROCESSING_DIR" -name "*_*" -type d -mtime +1 -exec rm -rf {} + 2>/dev/null || true
	fi

	exit $exit_code
}

# Set up signal traps
trap cleanup_on_exit EXIT
trap 'echo "Received SIGINT (Ctrl+C), cleaning up..."; exit 130' INT
trap 'echo "Received SIGTERM, cleaning up..."; exit 143' TERM
# --- Configuration ---
declare CONFIG_FILE="$HOME/Dev/book_expert/project.toml"
declare -a GEMINI_MODELS
GEMINI_MODELS=("gemini-2.5-flash" "gemini-2.5-pro" "gemini-2.5-flash-lite")

# --- Global Variables ---
declare OUTPUT_DIR=""
declare MAX_RETRIES=5
declare CONCEPT_MODEL=""
declare LOG_DIR=""
declare LOG_FILE=""
declare GOOGLE_API_KEY_VAR=""
declare PROCESSING_DIR=""
declare INPUT_DIR=""
declare API_RETRY_DELAY=60
declare FORCE=0
declare EXTRACTED_TEXT=""
declare EXTRACTED_CONCEPTS=""
declare GEMINI_RESPONSE=""
# Helper functions that need to be defined elsewhere in your script
error()
{
	echo "$1"
}

log()
{
	echo "$1"
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

	# Check Google API key if using Google API
	if [[ -n ${GOOGLE_API_KEY_VAR:-} && -z ${!GOOGLE_API_KEY_VAR:-} ]]; then
		echo "ERROR: API key environment variable '$GOOGLE_API_KEY_VAR' is not set or is empty."
		exit 1
	fi

	if [[ -z ${CONCEPT_MODEL:-} ]]; then
		echo "ERROR: CONCEPT_MODEL is not set."
		exit 1
	fi

	echo "INFO: NO DEPENDENCY ISSUES"
	print_line
}

# Replace your call_google_api function with this:
call_google_api()
{
	local model_name="$1"
	local prompt="$2"
	local b64_content="$3"
	local json_payload_file=""
	GEMINI_RESPONSE=""
	json_payload_file=$(mktemp)

	if [[ ! -f $json_payload_file ]]; then
		echo "ERROR: Failed to create temporary file for JSON payload"
		return 1
	fi

	# Create JSON payload using printf and here-doc to avoid argument length limits
	# Use jq to properly escape the prompt text, then construct the full JSON
	local escaped_prompt
	escaped_prompt=$(printf '%s' "$prompt" | jq -R .)

	cat >"$json_payload_file" <<EOF
{
	"contents": [{
		"parts": [
			{ "text": $escaped_prompt },
			{ "inline_data": {
				"mime_type": "image/png",
				"data": "$b64_content"
			}}
		]
	}]
}
EOF

	# Validate JSON structure
	if ! jq empty <"$json_payload_file"; then
		echo "ERROR: Generated invalid JSON payload"
		rm -f "$json_payload_file"
		return 1
	fi

	GEMINI_RESPONSE=$(curl \
		--silent --show-error \
		--connect-timeout 10 \
		--max-time 30 \
		--retry 3 \
		-H "x-goog-api-key: ${!GOOGLE_API_KEY_VAR}" \
		-H "Content-Type: application/json" \
		-X POST --data-binary "@$json_payload_file" \
		"https://generativelanguage.googleapis.com/v1beta/models/$model_name:generateContent")

	if [[ $GEMINI_RESPONSE ]]; then
		echo "INFO: GEMINI reposned with model $model_name"
		print_line

		return 0
	fi

	return 1
}

# And update try_gemini_models to not expect HTTP code in the file:
try_gemini_models()
{
	local prompt="$1"
	local b64_content="$2"
	local -a models=()
	GEMINI_RESPONSE=""
	models=("${GEMINI_MODELS[@]}")

	for model in "${models[@]}"; do
		echo "INFO: Trying model $model..."

		call_google_api "$model" "$prompt" "$b64_content"

		if [[ $GEMINI_RESPONSE ]]; then

			echo "SUCCESS: Model $model responded successfully"
			print_line
			return 0
		else
			# Reset
			echo "WARN: Trying a different model"
			continue
		fi
	done

	echo "ERROR: All Gemini models failed"
	print_line
	return 1
}

extract_text()
{
	echo "INFO: Text extraction"
	local b64_content=""
	local prompt=""

	b64_content="$1"

	# Validate input
	if [[ -z $b64_content ]]; then
		echo "ERROR: Empty base64 content provided to extract_text"
		return 1
	fi

	prompt="You are a Ph.D STEM expert level technical writer expert.Extract the complete readable text from the provided page. Write using clear, plain paragraphs suitable for narration. Rewrite any lists or structured elements descriptively in flowing prose ('the list contains..., the figure shows...'), not as bullet points or headers. Correct grammar and formatting for clarity and accessibility, expanding any abbreviations or technical terms for a Ph.D.-level listener. Omit all conversational, meta, or instructional content. Output only the transcribed page text, ready for natural TTS narration."

	for ((attempts = 0; attempts < MAX_RETRIES; attempts++)); do
		# Reset
		EXTRACTED_TEXT=""
		GEMINI_RESPONSE=""
		try_gemini_models "$prompt" "$b64_content"

		if [[ $GEMINI_RESPONSE ]]; then
			# Use timeout for JSON parsing
			EXTRACTED_TEXT=$(timeout 10s jq -r '.candidates[0].content.parts[0].text // empty' <<<"$GEMINI_RESPONSE")
			if [[ $EXTRACTED_TEXT ]]; then

				echo "SUCCESS: Text extracted successfully"
				return 0
			else
				echo "WARN: Empty or null response from API (attempt $((attempts + 1))/$MAX_RETRIES)"
			fi

		else
			echo "WARN: API call failed or invalid response format (attempt $((attempts + 1))/$MAX_RETRIES)"
		fi

		if [[ $((attempts + 1)) -lt $MAX_RETRIES ]]; then
			echo "INFO: Waiting ${API_RETRY_DELAY}s before retry..."
			sleep "$API_RETRY_DELAY"
		fi
	done

	echo "ERROR: Text extraction failed after $MAX_RETRIES attempts"
	return 1
}

extract_concepts()
{
	local b64_content=""
	local prompt=""
	GEMINI_RESPONSE=""

	b64_content="$1"

	# Validate input
	if [[ -z $b64_content ]]; then
		echo "ERROR: Empty base64 content provided to extract_concepts"
		return 1
	fi

	prompt="You are a STEM Nobel receiver scientist with deep knowledge. Identify and explain the underlying technical concepts and information found in this page. Write in clear, insightful, and engaging language suitable for an expert audience. Present technical ideas, code, formulas, data, and diagrams as a narrative, describing their meaning and significance as if contributing to a graduate-level technical textbook. Avoid all conversational phrasing, summaries, conclusions, introductions, or direct references to the image, page, or text. Focus deeply on conceptual clarity, providing context, analogies, and examples within a smooth, continuous explanation."

	for ((attempts = 0; attempts < MAX_RETRIES; attempts++)); do
		# Check overall timeout

		GEMINI_RESPONSE=""
		EXTRACTED_CONCEPTS=""
		try_gemini_models "$prompt" "$b64_content"

		if [[ $GEMINI_RESPONSE ]]; then
			# Use timeout for JSON parsing
			EXTRACTED_CONCEPTS=$(timeout 10s jq -r '.candidates[0].content.parts[0].text // empty' <<<"$GEMINI_RESPONSE")
			if [[ $EXTRACTED_CONCEPTS ]]; then
				echo "SUCCESS: Concepts extracted successfully"

				return 0
			else
				echo "WARN: Empty or null response from API (attempt $((attempts + 1))/$MAX_RETRIES)"
				echo "INFO: Waiting ${API_RETRY_DELAY}s before retry..."
				sleep "$API_RETRY_DELAY"
				continue
			fi
		fi

	done

	echo "ERROR: Concept extraction failed after $MAX_RETRIES attempts"
	return 1
}

process_single_png()
{
	# Assign variables one per line
	local png="$1"
	local storage_dir="$2"
	local max_retries="${MAX_RETRIES:-5}"
	local retries=0
	local base_name output_file=""
	local b64_content=""
	local base_name=""
	local output_file=""
	local base64_exit_code=0
	local b64_content=""
	# Reset
	EXTRACTED_TEXT=""
	EXTRACTED_CONCEPTS=""

	base_name=$(basename "$png" .png)
	output_file="$storage_dir/${base_name}.txt"

	mkdir -p "$storage_dir"

	if [[ -s $output_file ]]; then
		echo "SKIP: $png already processed."
		print_line
		return 0
	fi

	b64_content=$(base64 -w 0 "$png" 2>&1)
	base64_exit_code=$?

	if [[ $base64_exit_code -ne 0 ]]; then
		error "ERROR: Base64 encoding failed for file: $png - $b64_content"
		print_line
		return 1
	fi

	# Additional validation: check if b64_content is not empty
	if [[ -z $b64_content ]]; then
		error "ERROR: Base64 encoding produced empty result for file: $png"
		print_line
		return 1
	fi

	while [[ $retries -lt $max_retries ]]; do
		echo "INFO: Processing: $png"
		print_line

		# Reset
		EXTRACTED_TEXT=""
		extract_text "${b64_content}"

		if [[ $EXTRACTED_TEXT ]]; then
			echo "$EXTRACTED_TEXT" >"$output_file"
			echo "SUCCESS: EXTRACTED Text saved -> '$output_file'"
			print_line

			extract_concepts "$b64_content"
			if [[ $EXTRACTED_CONCEPTS ]]; then
				echo "$EXTRACTED_CONCEPTS" >>"$output_file"
				echo "SUCCESS: Concepts extracted -> '$output_file'"
				echo "SUCCESS: $output_file"
				print_line
				# Reset
				EXTRACTED_TEXT=""
				EXTRACTED_CONCEPTS=""
				return 0
			else
				echo "WARN: Concept extraction failed for: $png"
				print_line
			fi
		else
			echo "Text extraction failed for: $png"
			print_line
		fi

		retries=$((retries + 1))
		if [[ $retries -lt $max_retries ]]; then
			echo "INFO: RETRYING $png (attempt $((retries + 1))/$max_retries)"
			sleep "$API_RETRY_DELAY"
		else
			echo "ERROR: FAILED TO PROCESS $png"
		fi
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
	echo "INFO: Removing old TEMP directories with the same base directory"
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

		# Initialize counts
		text_count=0
		png_count=0

		# Check text files
		if [[ -d $text_path ]]; then
			text_count=$(find "$text_path" -type f | wc -l)
		fi

		# Check PNG files
		if [[ -d $dir_path ]]; then
			png_count=$(find "$dir_path" -type f | wc -l)

			if [[ $png_count -eq $text_count ]]; then
				echo "INFO: SKIPPING $dir_path"
				echo "INFO: Remove the text directory if you want to generate the text"
				print_line
			elif [[ $png_count -gt 0 && $text_count -gt 0 && $FORCE -eq 0 ]]; then
				echo "INFO: SKIPPING $dir_path"
				echo "INFO: Remove the text directory if you want to generate the text"
				print_line
			elif [[ $png_count -gt 0 && $text_count -gt 0 && $FORCE -eq 1 ]]; then

				echo "INFO: $dir_path exists and contains $png_count file(s)"
				echo "INFO: Force is $FORCE"
				echo "INFO: $text_path has $text_count text files, the process will resume after the last text file"
				print_line
				PNG_DIRS_GLOBAL+=("$dir_path")
			elif [[ $png_count -gt 0 ]]; then
				echo "INFO: Adding $dir_path in the processing queue"
				PNG_DIRS_GLOBAL+=("$dir_path")
				print_line
			else
				echo "INFO: Normally, it should not reach here"
				print_line
			fi
		else
			echo "$dir_path does not exist"
			print_line
		fi
	done

	if [[ ${#PNG_DIRS_GLOBAL[@]} -eq 0 ]]; then
		echo "ERROR: No directories with valid PNG files found"
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
	CONCEPT_MODEL=$(get_config "nvidia_api.concept_model")
	LOG_DIR=$(get_config "logs_dir.png_to_text")
	PROCESSING_DIR=$(get_config "processing_dir.png_to_text")
	MAX_RETRIES=$(get_config "retry.max_retries")
	API_RETRY_DELAY=$(get_config "retry.retry_delay_seconds")
	# Load Google API configuration (if available)
	GOOGLE_API_KEY_VAR=$(get_config "google_api.api_key_variable" 2>/dev/null || true)
	FORCE=$(get_config "settings.force")

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
	echo "INFO: CLEANING UP"
	cleanup_on_exit

}

# Entry point for the script
main "$@"
