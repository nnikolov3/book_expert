#!/usr/bin/env bash

# png_to_page_text.sh

# Design: Niko Nikolov
# Code: Various LLMs

# ------------------------------------------------------------------------------------
# ## Code Guidelines to LLMs
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
# - DO NOT USE 2>>"$LOG_FILE"
# - DO NOT USE ((i++)) instead use i=$((i + 1))
# - DO NOT IGNORE the guidelines
# - AVOID Redirections 2>/dev/null
# - Declare / assign each variable on its own line
# COMMENTS SHOULD NOT BE REMOVED, INCONSISTENCIES SHOULD BE UPDATED WHEN DETECTED
# ------------------------------------------------------------------------------------

set -euo pipefail

# Logging helpers (extend to also write to file if desired)
log()
{
	echo "INFO: -> $1"
	print_line
}
error()
{
	echo "ERROR: -> $1"
	print_line
}
success()
{
	echo "SUCCESS: -> $1"
	print_line
}
warn()
{
	echo "WARN: -> $1"
	print_line
}
print_line()
{
	echo "================================================================"
}

# Handle script exits and clean up processing directories on exit or signal.
cleanup_on_exit()
{
	local exit_code
	exit_code=$?
	log "Script interrupted or exiting with code $exit_code"

	# Remove old processing directories
	if [[ -n ${PROCESSING_DIR:-} ]]; then
		log "Cleaning up processing directories..."
		find "$PROCESSING_DIR" -name "*_*" -type d -mtime +1 -exec rm -rf {} + 2>/dev/null || true
	fi
	exit $exit_code
}

trap cleanup_on_exit EXIT
trap 'log "Received SIGINT (Ctrl+C), cleaning up..."; exit 130' INT
trap 'log "Received SIGTERM, cleaning up..."; exit 143' TERM

# --- Configuration: These should be defined in project.toml for flexibility ---
declare CONFIG_FILE="$HOME/Dev/book_expert/project.toml"
declare -a GEMINI_MODELS=("gemini-2.5-flash-lite" "gemini-2.5-flash" "gemini-2.5-pro")
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

# Load values from config file using yq (fail the script if missing)
get_config()
{
	local key="$1"
	local value
	value=$(yq -r ".${key} // \"\"" "$CONFIG_FILE")
	if [[ -z $value ]]; then
		error "Missing or empty configuration key $key in $CONFIG_FILE"
		return 1
	fi
	echo "$value"
	return 0
}

# System dependencies check for reliable automation
check_dependencies()
{
	local deps=("yq" "jq" "curl" "base64" "tesseract" "rsync" "mktemp" "nproc" "awk")
	for dep in "${deps[@]}"; do
		if ! command -v "$dep" >/dev/null; then
			error "'$dep' is not installed."
			exit 1
		fi
	done
	if [[ -n ${GOOGLE_API_KEY_VAR:-} && -z ${!GOOGLE_API_KEY_VAR:-} ]]; then
		error "API key environment variable '$GOOGLE_API_KEY_VAR' is not set or is empty."
		exit 1
	fi
	if [[ -z ${CONCEPT_MODEL:-} ]]; then
		error "CONCEPT_MODEL is not set."
		exit 1
	fi
	log "NO DEPENDENCY ISSUES"
}

# Use Gemini API for text and concept extraction; retry on failures.
call_google_api()
{
	local model_name="$1"
	local prompt="$2"
	local b64_content="$3"
	local json_payload_file
	GEMINI_RESPONSE=""
	json_payload_file=$(mktemp)

	local escaped_prompt
	escaped_prompt=$(printf '%s' "$prompt" | jq -R .)

	# Construct JSON payload for Gemini endpoint
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

	# Validate payload
	if ! jq empty <"$json_payload_file"; then
		error "Generated invalid JSON payload"
		rm -f "$json_payload_file"
		return 1
	fi

	# API call; we never mix models in one function to preserve atomicity
	GEMINI_RESPONSE=$(curl \
		--silent --show-error \
		--connect-timeout 10 \
		--max-time 30 \
		--retry 3 \
		-H "x-goog-api-key: ${!GOOGLE_API_KEY_VAR}" \
		-H "Content-Type: application/json" \
		-X POST --data-binary "@$json_payload_file" \
		"https://generativelanguage.googleapis.com/v1beta/models/$model_name:generateContent")

	rm -f "$json_payload_file"

	if [[ $GEMINI_RESPONSE ]]; then
		log "GEMINI responded with model $model_name"
		return 0
	fi
	return 1
}

# Try all configured models sequentially, ensuring robust fallback strategy.
try_gemini_models()
{
	local prompt="$1"
	local b64_content="$2"
	local -a models=("${GEMINI_MODELS[@]}")
	GEMINI_RESPONSE=""
	for model in "${models[@]}"; do
		log "Trying model $model..."
		call_google_api "$model" "$prompt" "$b64_content"
		if [[ $GEMINI_RESPONSE ]]; then
			success "Model $model responded successfully"
			return 0
		else
			warn "Trying a different model"
		fi
	done
	error "All Gemini models failed"
	return 1
}

# Extract narration-ready text from an image (PNG) in base64.
extract_text()
{
	log "Text extraction"
	local b64_content="$1"
	if [[ -z $b64_content ]]; then
		error "Empty base64 content provided to extract_text"
		return 1
	fi
	# Prompt tuned for F5-TTS/E2TTS_Base, yielding full text for audio narration
	local prompt="You are a Ph.D STEM expert level technical writer expert. Extract the complete readable text from the provided page. Write using clear, plain paragraphs suitable for narration. Rewrite any lists or structured elements descriptively in flowing prose ('the list contains..., the figure shows...'), not as bullet points or headers. Correct grammar and formatting for clarity and accessibility, expanding any abbreviations or technical terms for a Ph.D.-level listener. Omit all conversational, meta, or instructional content. Output only the transcribed page text, ready for natural TTS narration."

	for ((attempts = 0; attempts < MAX_RETRIES; attempts++)); do
		EXTRACTED_TEXT=""
		GEMINI_RESPONSE=""
		try_gemini_models "$prompt" "$b64_content"
		if [[ $GEMINI_RESPONSE ]]; then
			EXTRACTED_TEXT=$(timeout 10s jq -r '.candidates[0].content.parts[0].text // empty' <<<"$GEMINI_RESPONSE")
			if [[ $EXTRACTED_TEXT ]]; then
				success "Text extracted successfully"
				return 0
			else
				warn "Empty or null response from API (attempt $((attempts + 1))/$MAX_RETRIES)"
			fi
		else
			warn "API call failed or invalid response format (attempt $((attempts + 1))/$MAX_RETRIES)"
		fi
		if [[ $((attempts + 1)) -lt $MAX_RETRIES ]]; then
			log "Waiting ${API_RETRY_DELAY}s before retry..."
			sleep "$API_RETRY_DELAY"
		fi
	done
	error "Text extraction failed after $MAX_RETRIES attempts"
	return 1
}

# Extract and narrate high-level concepts for technical learning scenarios
extract_concepts()
{
	local b64_content="$1"
	GEMINI_RESPONSE=""
	if [[ -z $b64_content ]]; then
		error "Empty base64 content provided to extract_concepts"
		return 1
	fi
	local prompt="You are a STEM Nobel receiver scientist with deep knowledge. Identify and explain the underlying technical concepts and information found in this page. Write in clear, insightful, and engaging language suitable for an expert audience. Present technical ideas, code, formulas, data, and diagrams as a narrative, describing their meaning and significance as if contributing to a graduate-level technical textbook. Avoid all conversational phrasing, summaries, conclusions, introductions, or direct references to the image, page, or text. Focus deeply on conceptual clarity, providing context, analogies, and examples within a smooth, continuous explanation."

	for ((attempts = 0; attempts < MAX_RETRIES; attempts++)); do
		GEMINI_RESPONSE=""
		EXTRACTED_CONCEPTS=""
		try_gemini_models "$prompt" "$b64_content"
		if [[ $GEMINI_RESPONSE ]]; then
			EXTRACTED_CONCEPTS=$(timeout 10s jq -r '.candidates[0].content.parts[0].text // empty' <<<"$GEMINI_RESPONSE")
			if [[ $EXTRACTED_CONCEPTS ]]; then
				success "Concepts extracted successfully"
				return 0
			else
				warn "Empty or null response from API (attempt $((attempts + 1))/$MAX_RETRIES)"
				log "Waiting ${API_RETRY_DELAY}s before retry..."
				sleep "$API_RETRY_DELAY"
				continue
			fi
		fi
	done

	error "Concept extraction failed after $MAX_RETRIES attempts"
	return 1
}

# Process one PNG file from base64 to extracted text/concepts, using robust error handling and logging.
process_single_png()
{
	local png="$1"
	local storage_dir="$2"
	local max_retries="${MAX_RETRIES:-5}"
	local retries=0
	local base_name
	local output_file
	local b64_content
	local base64_exit_code=0

	EXTRACTED_TEXT=""
	EXTRACTED_CONCEPTS=""
	base_name=$(basename "$png" .png)
	output_file="$storage_dir/${base_name}.txt"
	mkdir -p "$storage_dir"

	# Skip processing if text output already exists (idempotent workflow)
	if [[ -s $output_file ]]; then
		log "SKIP: $png already processed."
		return 0
	fi

	b64_content=$(base64 -w 0 "$png" 2>&1)
	base64_exit_code=$?
	if [[ $base64_exit_code -ne 0 ]]; then
		error "Base64 encoding failed for file: $png - $b64_content"
		return 1
	fi
	if [[ -z $b64_content ]]; then
		error "Base64 encoding produced empty result for file: $png"
		return 1
	fi

	while [[ $retries -lt $max_retries ]]; do
		log "Processing: $png"
		EXTRACTED_TEXT=""
		extract_text "${b64_content}"
		if [[ $EXTRACTED_TEXT ]]; then
			echo "$EXTRACTED_TEXT" >"$output_file"
			success "EXTRACTED Text saved -> '$output_file'"
			extract_concepts "$b64_content"
			if [[ $EXTRACTED_CONCEPTS ]]; then
				echo "$EXTRACTED_CONCEPTS" >>"$output_file"
				success "Concepts extracted -> '$output_file'"
				success "$output_file"
				EXTRACTED_TEXT=""
				EXTRACTED_CONCEPTS=""
				return 0
			else
				warn "Concept extraction failed for: $png"
			fi
		else
			warn "Text extraction failed for: $png"
		fi
		retries=$((retries + 1))
		if [[ $retries -lt $max_retries ]]; then
			log "RETRYING $png (attempt $((retries + 1))/$max_retries)"
			sleep "$API_RETRY_DELAY"
		else
			error "FAILED TO PROCESS $png"
		fi
	done
	error "Failed to process $png after $max_retries retries"
	return 1
}

# Batch process all PNGs in a directory.
process_pngs()
{
	local -a png_files=("$@")
	local storage_dir="${png_files[-1]}"
	unset 'png_files[-1]'
	for png in "${png_files[@]}"; do
		if ! process_single_png "$png" "$storage_dir"; then
			error "Failed to process $png"
		fi
	done
	log "All processing complete."
}

# Setup processing dirs, verify staged files, trigger actual PNG processing.
pre_process_png()
{
	local png_directory="$1"
	local processing_png_dir="$2"
	local storage_dir="$3"

	mkdir -p "$PROCESSING_DIR"
	mkdir -p "$storage_dir"
	log "STORAGE: $storage_dir"

	# Name per document, separate temp dir for each run.
	local safe_name
	safe_name=$(echo "$processing_png_dir" | tr '/' '_')
	log "Removing old TEMP directories with the same base directory"
	rm -rf "$PROCESSING_DIR/${safe_name}"_*
	local temp_dir
	temp_dir=$(mktemp -d "$PROCESSING_DIR/${safe_name}_XXXXXX")
	log "STAGING TO NEW PROCESSING DIR: $temp_dir"

	rsync -a --info=progress2 "$png_directory/" "$temp_dir/"
	local output
	output=$(rsync -a --checksum --dry-run "$png_directory/" "$temp_dir/")
	if [[ -z $output ]]; then
		success "STAGING COMPLETE"
	else
		error "Files differ:"
		error "$output"
	fi

	# List all PNGs to process in order
	declare -a png_array=()
	mapfile -t png_array < <(find "$temp_dir" -type f -name "*.png" | sort -V)
	if [ ${#png_array[@]} -eq 0 ]; then
		error "No png files? This is odd."
		return 1
	else
		success "Found pngs. Processing ..."
		if process_pngs "${png_array[@]}" "$storage_dir"; then
			success "PNG processing completed successfully for $temp_dir"
		else
			error "PNG processing failed"
			return 1
		fi
	fi
}

# Find document directories that need processing, create processing queue.
declare -a PNG_DIRS_GLOBAL=()
are_png_in_dirs()
{
	local -a pdf_array=("$@")
	PNG_DIRS_GLOBAL=()
	local dir_path
	local text_path
	local png_count
	local text_count

	for pdf_name in "${pdf_array[@]}"; do
		log "Checking document: $pdf_name"
		dir_path="$OUTPUT_DIR/$pdf_name/png"
		text_path="$OUTPUT_DIR/$pdf_name/text"
		text_count=0
		png_count=0
		if [[ -d $text_path ]]; then
			text_count=$(find "$text_path" -type f | wc -l)
		fi
		if [[ -d $dir_path ]]; then
			png_count=$(find "$dir_path" -type f -name "*.png" | wc -l)
			if [[ $png_count -eq $text_count ]]; then
				log "SKIPPING $dir_path"
				log "Remove the text directory if you want to generate the text"
			elif [[ $png_count -gt 0 && $text_count -gt 0 && $FORCE -eq 0 ]]; then
				log "SKIPPING $dir_path"
				log "Remove the text directory if you want to generate the text"
			elif [[ $png_count -gt 0 && $text_count -gt 0 && $FORCE -eq 1 ]]; then
				log "$dir_path exists and contains $png_count file(s)"
				log "Force is $FORCE"
				log "$text_path has $text_count text files, the process will resume after the last text file"
				PNG_DIRS_GLOBAL+=("$dir_path")
			elif [[ $png_count -gt 0 ]]; then
				log "Adding $dir_path in the processing queue"
				PNG_DIRS_GLOBAL+=("$dir_path")
			else
				log "Normally, it should not reach here"
			fi
		else
			log "$dir_path does not exist"
		fi
	done

	if [[ ${#PNG_DIRS_GLOBAL[@]} -eq 0 ]]; then
		error "No directories with valid PNG files found"
		return 1
	else
		success "Found directories to process"
		return 0
	fi
}

# Utility: get base and parent dir for naming temp dirs.
get_last_two_dirs()
{
	local full_path="$1"
	local parent_dir
	parent_dir=$(basename "$(dirname "$full_path")")
	local current_dir
	current_dir=$(basename "$full_path")
	echo "$parent_dir/$current_dir"
}

# Entrypoint: initialize, config, discover, process, clean up.
main()
{
	local date_time
	date_time=$(date +%c)
	log "START CONVERSION: $date_time"
	log "Loading configurations"
	INPUT_DIR=$(get_config "paths.input_dir")
	OUTPUT_DIR=$(get_config "paths.output_dir")
	CONCEPT_MODEL=$(get_config "nvidia_api.concept_model")
	LOG_DIR=$(get_config "logs_dir.png_to_text")
	PROCESSING_DIR=$(get_config "processing_dir.png_to_text")
	MAX_RETRIES=$(get_config "retry.max_retries")
	API_RETRY_DELAY=$(get_config "retry.retry_delay_seconds")
	GOOGLE_API_KEY_VAR=$(get_config "google_api.api_key_variable")
	FORCE=$(get_config "settings.force")
	mkdir -p "$PROCESSING_DIR"
	mkdir -p "$LOG_DIR" || {
		error "Failed to create log directory: $LOG_DIR"
		exit 1
	}
	LOG_FILE="$LOG_DIR/log_$(date +'%Y%m%d_%H%M%S').log"
	touch "$LOG_FILE" || {
		error "Failed to create log file."
		exit 1
	}
	log "Script started. Log file: $LOG_FILE"
	log "Checking dependencies"
	check_dependencies

	declare -a pdf_array=()
	mapfile -t pdf_array < <(find "$INPUT_DIR" -type f -name "*.pdf" -exec basename {} .pdf \;)
	if [ ${#pdf_array[@]} -eq 0 ]; then
		error "No pdf files in input directory"
		exit 1
	else
		log "Found pdf for processing. Checking for valid png .."
	fi

	if are_png_in_dirs "${pdf_array[@]}"; then
		for png_path in "${PNG_DIRS_GLOBAL[@]}"; do
			log "PROCESSING: $png_path"
			staging_dir_name=$(get_last_two_dirs "$png_path")
			parent_dir=$OUTPUT_DIR/$(basename "$(dirname "$png_path")")/text
			pre_process_png "$png_path" "$staging_dir_name" "$parent_dir"
		done
	fi

	log "All processing jobs completed."
	log "CLEANING UP"
	cleanup_on_exit
}

main "$@"
