#!/usr/bin/env bash

# Design: Niko Nikolov
# Code: Niko and LLMs
# Purpose: Extract and enrich text from PNGs using OCR + LLMs

set -euo pipefail

# Global constants (readonly) - derived from TOML
declare -r GEMINI_MODELS=("gemini-2.5-flash" "gemini-2.5-flash-lite" "gemini-2.5-pro")

# Global state (non-readonly, but prefixed with GLOBAL) - alphabetical order
declare EXTRACT_CONCEPTS_PROMPT=""
declare EXTRACT_TEXT_PROMPT=""
declare EXTRACTED_TEXT=""
declare FORCE_GLOBAL=0
declare GEMINI_RESPONSE=""
declare GOOGLE_API_KEY_VAR_GLOBAL=""
declare INPUT_GLOBAL=""
declare LOG_DIR_GLOBAL=""
declare LOG_FILE_GLOBAL=""
declare OUTPUT_GLOBAL=""
declare PROCESSING_DIR_GLOBAL=""
declare DPI_GLOBAL=""

# --- LOGGING & CLEANUP ---
cleanup_on_exit()
{
	local exit_code
	exit_code=$?
	echo "Script interrupted or exiting with code $exit_code"

	if [[ -n ${PROCESSING_DIR_GLOBAL:-} ]]; then
		echo "Cleaning up old processing directories..."
		find "$PROCESSING_DIR_GLOBAL" -name "*_*" -type d -mtime +1 -exec rm -rf {} + 2>/dev/null || true
	fi
	exit "$exit_code"
}

trap cleanup_on_exit EXIT
trap 'log_info "Received SIGINT (Ctrl+C), cleaning up..."; exit 130' INT
trap 'log_info "Received SIGTERM, cleaning up..."; exit 143' TERM

# --- DEPENDENCY CHECK ---
check_dependencies()
{
	local -a deps=("yq" "jq" "curl" "base64" "tesseract" "rsync" "mktemp")
	local dep

	for dep in "${deps[@]}"; do
		if ! command -v "$dep" >/dev/null 2>&1; then
			echo "Dependency not found: $dep"
			exit 1
		fi
	done

	if [[ -z ${!GOOGLE_API_KEY_VAR_GLOBAL:-} ]]; then
		echo "Environment variable $GOOGLE_API_KEY_VAR_GLOBAL is not set."
		exit 1
	fi

	echo "All dependencies satisfied."
}

call_google_api()
{
	local b64_content="$3"
	local b64_file
	local json_payload_file
	local model_name="$1"
	local prompt="$2"
	local prompt_file

	GEMINI_RESPONSE=""

	# Write prompt and image b64 to temp files
	prompt_file=$(mktemp)
	b64_file=$(mktemp)
	json_payload_file=$(mktemp)
	printf "%s" "$prompt" >"$prompt_file"
	printf "%s" "$b64_content" >"$b64_file"

	# Compose API payload as per Gemini docs
	jq -n \
		--rawfile prompt "$prompt_file" \
		--rawfile b64 "$b64_file" '
      {
        contents: [
          {
            parts: [
              { text: $prompt },
              { inlineData: { mimeType: "image/png", data: $b64 } }
            ]
          }
        ]
      }' >"$json_payload_file"

	# Call Gemini API with proper content-type and authentication
	GEMINI_RESPONSE=$(
		curl -sS \
			-H "x-goog-api-key: ${!GOOGLE_API_KEY_VAR_GLOBAL}" \
			-H "Content-Type: application/json" \
			-X POST \
			"https://generativelanguage.googleapis.com/v1beta/models/${model_name}:generateContent" \
			-d @"$json_payload_file"
	)

	# Cleanup
	rm -f "$prompt_file" "$b64_file" "$json_payload_file"
	return 0
}

# Try all configured models sequentially, ensuring robust fallback strategy.
try_gemini_models()
{
	local b64_content="$2"
	local fail="$3"
	local model="${GEMINI_MODELS[$fail]}"
	local prompt="$1"
	local status

	GEMINI_RESPONSE=""
	log_info "Trying model $model..."

	if [[ $fail -lt ${#GEMINI_MODELS[@]} ]]; then
		call_google_api "$model" "$prompt" "$b64_content"
		status="$?"
	fi

	if [[ -n $GEMINI_RESPONSE && $status -eq 0 ]]; then
		# Check for API error in response
		local error_message
		error_message=$(jq -r '.error.message // empty' <<<"$GEMINI_RESPONSE" 2>/dev/null || echo "")
		if [[ -n $error_message ]]; then
			log_warn "API returned error: $error_message"
			fail=$((fail + 1))
			if [[ $fail -lt ${#GEMINI_MODELS[@]} ]]; then
				try_gemini_models "$prompt" "$b64_content" "$fail"
			else
				log_error "All Gemini models failed"
				return 1
			fi
		else
			log_success "Model $model responded successfully"
			return 0
		fi
	else
		log_warn "Trying a different model"
		fail=$((fail + 1))
		log_warn "Fail count is $fail"
		if [[ $fail -lt ${#GEMINI_MODELS[@]} ]]; then
			try_gemini_models "$prompt" "$b64_content" "$fail"
		else
			log_error "All Gemini models failed"
			return 1
		fi
	fi
}

# --- OCR: Tesseract Text Extraction ---
extract_tesseract_text()
{
	local exit_code
	local png_file="$1"
	local tesseract_output

	tesseract_output=$(
		tesseract \
			"$png_file" \
			stdout \
			-l 'equ+eng' \
			-l 'eng' \
			--dpi "$DPI_GLOBAL" \
			--oem 3 \
			--psm 1 2>&1
	)
	exit_code=$?

	if [[ $exit_code -eq 0 && -n $tesseract_output ]]; then
		printf '%s' "$tesseract_output"
		return 0
	else
		log_warn "Tesseract failed or returned empty for: $png_file"
		return 1
	fi
}

extract_text()
{
	local b64_content="$1"
	local fail=0
	local -r prompt=$(printf "%s" "$EXTRACT_TEXT_PROMPT")

	log_info "Enhanced text extraction"

	if [[ -z $b64_content ]]; then
		log_error "Empty base64 content provided to extract_text"
		return 1
	fi

	EXTRACTED_TEXT=""
	GEMINI_RESPONSE=""

	if try_gemini_models "$prompt" "$b64_content" "$fail"; then
		EXTRACTED_TEXT=$(jq -r '.candidates[0].content.parts[0].text // empty' <<<"$GEMINI_RESPONSE")
		if [[ -n $EXTRACTED_TEXT && $EXTRACTED_TEXT != "null" ]]; then
			log_success "Enhanced text extracted successfully"
			return 0
		else
			log_warn "Empty or null response from API"
			return 1
		fi
	else
		log_error "Failed to extract text"
		return 1
	fi
}

# Extract concepts optimized for clean_text.sh transformations
extract_concepts()
{
	local b64_content="$1"
	local fail=0
	local -r prompt=$(printf "%s" "$EXTRACT_CONCEPTS_PROMPT")

	GEMINI_RESPONSE=""

	if [[ -z $b64_content ]]; then
		log_error "Empty base64 content provided to extract_concepts"
		return 1
	fi

	EXTRACTED_CONCEPTS=""
	GEMINI_RESPONSE=""

	if try_gemini_models "$prompt" "$b64_content" "$fail"; then
		EXTRACTED_CONCEPTS=$(jq -r '.candidates[0].content.parts[0].text // empty' <<<"$GEMINI_RESPONSE")
		if [[ -n $EXTRACTED_CONCEPTS && $EXTRACTED_CONCEPTS != "null" ]]; then
			log_success "Concepts extracted successfully"
			GEMINI_RESPONSE="" # Reset
			return 0
		else
			log_warn "Empty or null response from API"
			return 1
		fi
	else
		log_error "Concept extraction failed"
		return 1
	fi
}

# Process one PNG file with three-stage extraction: Tesseract -> API Text -> API Concepts
process_single_png()
{
	local b64_content
	local base64_exit_code=0
	local base_name
	local output_file
	local png="$1"
	local storage_dir="$2"

	EXTRACTED_CONCEPTS=""
	EXTRACTED_TEXT=""
	TESSERACT_TEXT=""
	base_name=$(basename "$png" .png)
	output_file="$storage_dir/${base_name}.txt"
	mkdir -p "$storage_dir"

	# Skip processing if text output already exists (idempotent workflow)
	if [[ -s $output_file ]]; then
		log_info "SKIP: $png already processed."
		return 0
	fi

	# Prepare base64 content for API calls
	b64_content=$(base64 -w 0 "$png" 2>&1)
	base64_exit_code="$?"
	if [[ $base64_exit_code -ne 0 ]]; then
		log_error "Base64 encoding failed for file: $png - $b64_content"
		return 1
	fi
	if [[ -z $b64_content ]]; then
		log_error "Base64 encoding produced empty result for file: $png"
		return 1
	fi

	log_info "Processing: $png"

	# Stage 1: Tesseract OCR extraction
	TESSERACT_TEXT=""
	if TESSERACT_TEXT=$(extract_tesseract_text "$png"); then
		echo "$TESSERACT_TEXT" >"$output_file"
		log_success "Tesseract text appended to '$output_file'"
	else
		log_error "Tesseract extraction failed, continuing with API extraction only"
		return 1
	fi

	# Stage 2: Extraction via LLM
	EXTRACTED_TEXT=""
	if extract_text "${b64_content}"; then
		echo "$EXTRACTED_TEXT" >>"$output_file"
		log_success "Enhanced text appended to '$output_file'"
	else
		log_error "Failed to extract text for $png!"
		return 1
	fi

	# Stage 3: Concept extraction
	EXTRACTED_CONCEPTS=""
	if extract_concepts "$b64_content"; then
		echo "$EXTRACTED_CONCEPTS" >>"$output_file"
		log_success "Concepts appended to '$output_file'"
		log_success "All three stages completed for $output_file"
		# Resetting
		EXTRACTED_CONCEPTS=""
		EXTRACTED_TEXT=""
		GEMINI_RESPONSE=""
		TESSERACT_TEXT=""
		return 0
	else
		log_warn "Concept extraction failed for: $png"
		return 1
	fi
}

# --- BATCH PROCESS: PNGs in Directory ---
process_png_directory()
{
	local file
	local output_dir="$2"
	local png_dir="$1"
	local -a png_files

	readarray -t png_files < <(find "$png_dir" -type f -name "*.png" | sort -V)

	if [[ ${#png_files[@]} -eq 0 ]]; then
		log_warn "No PNG files found in $png_dir"
		return 1
	fi

	log_info "Processing ${#png_files[@]} PNGs from $png_dir"

	for file in "${png_files[@]}"; do
		if ! process_single_png "$file" "$output_dir"; then
			log_error "Failed to process $file"
			return 1
		fi
	done

	log_success "All PNGs processed in $png_dir"
	return 0
}

# --- STAGING: Copy PNGs to Temp Dir ---
stage_png_directory()
{
	local diff_check
	local output_dir="$3"
	local safe_name
	local source_dir="$1"
	local temp_base="$2"
	local temp_dir

	safe_name=$(echo "$temp_base" | tr '/' '_')
	temp_dir=$(mktemp -d "$PROCESSING_DIR_GLOBAL/${safe_name}_XXXXXX")

	log_info "Staging $source_dir to $temp_dir"

	rsync -a --info=progress2 "$source_dir/" "$temp_dir/"

	diff_check=$(rsync -a --checksum --dry-run "$source_dir/" "$temp_dir/" 2>&1)
	if [[ -n $diff_check ]]; then
		log_warn "Files differ during staging: $diff_check"
	fi

	if ! process_png_directory "$temp_dir" "$output_dir"; then
		log_error "Processing failed for staged directory: $temp_dir"
		return 1
	fi

	log_success "Staged and processed: $temp_dir"
	return 0
}

# --- DISCOVERY: Find PDFs and Their PNG Directories ---
discover_png_directories()
{
	local -a dirs_to_process
	local input_dir="$1"
	local output_dir="$2"
	local -a pdf_basenames
	local pdf_name
	local png_count
	local png_dir
	local text_count
	local text_dir

	readarray -t pdf_basenames < <(find "$input_dir" -type f -name "*.pdf" -exec basename {} .pdf \;)

	if [[ ${#pdf_basenames[@]} -eq 0 ]]; then
		log_error "No PDF files found in input directory: $input_dir"
		return 1
	fi

	log_info "Found ${#pdf_basenames[@]} PDFs to process."

	for pdf_name in "${pdf_basenames[@]}"; do
		png_dir="$output_dir/$pdf_name/png"
		text_dir="$output_dir/$pdf_name/text"

		if [[ ! -d $png_dir ]]; then
			log_info "SKIP: PNG directory missing: $png_dir"
			continue
		fi

		png_count=$(find "$png_dir" -type f -name "*.png" 2>/dev/null | wc -l)

		if [[ $png_count -eq 0 ]]; then
			log_info "SKIP: No PNGs in $png_dir"
			continue
		fi

		if [[ -d $text_dir ]] && [[ $FORCE_GLOBAL -eq 0 ]]; then
			text_count=$(find "$text_dir" -type f -name "*.txt" 2>/dev/null | wc -l)
			if [[ $text_count -ge $png_count ]]; then
				log_info "SKIP: Text already exists for $pdf_name. Use force=1 to override."
				continue
			fi
		fi

		dirs_to_process+=("$png_dir")
	done

	if [[ ${#dirs_to_process[@]} -eq 0 ]]; then
		log_error "No directories require processing."
		return 1
	fi

	# Export for use in main
	PNG_DIRS_GLOBAL=("${dirs_to_process[@]}")
	return 0
}

# --- UTILITY: Get last two path components ---
get_last_two_path_components()
{
	local current
	local parent
	local path="$1"

	parent=$(basename "$(dirname "$path")")
	current=$(basename "$path")
	printf '%s/%s' "$parent" "$current"
}

# --- MAIN ENTRYPOINT ---
main()
{
	local logger_script="helpers/logging_utils_helper.sh"
	local png_dir
	local staging_name
	local text_output_dir

	echo "|=================START: png_to_text pipeline===================="

	# Load configuration
	EXTRACT_CONCEPTS_PROMPT=$(helpers/get_config_helper.sh 'prompts.extract_concepts.prompt')
	EXTRACT_TEXT_PROMPT=$(helpers/get_config_helper.sh 'prompts.extract_text.prompt')
	FORCE_GLOBAL=$(helpers/get_config_helper.sh 'settings.force')
	GOOGLE_API_KEY_VAR_GLOBAL=$(helpers/get_config_helper.sh 'google_api.api_key_variable')
	INPUT_GLOBAL=$(helpers/get_config_helper.sh 'paths.input_dir')
	LOG_DIR_GLOBAL=$(helpers/get_config_helper.sh 'logs_dir.png_to_text')
	OUTPUT_GLOBAL=$(helpers/get_config_helper.sh 'paths.output_dir')
	PROCESSING_DIR_GLOBAL=$(helpers/get_config_helper.sh 'processing_dir.png_to_text')
	DPI_GLOBAL=$(helpers/get_config_helper.sh 'settings.dpi')

	# Validate and create directories
	mkdir -p "$PROCESSING_DIR_GLOBAL"
	mkdir -p "$LOG_DIR_GLOBAL"

	LOG_FILE_GLOBAL="$LOG_DIR_GLOBAL/log_$(date +'%Y%m%d_%H%M%S').log"
	touch "$LOG_FILE_GLOBAL"
	export LOG_FILE="$LOG_FILE_GLOBAL"

	echo "Log file created: $LOG_FILE_GLOBAL"

	if [[ ! -f $logger_script ]]; then
		echo "ERROR: Logging helper not found: $logger_script" >&2
		exit 1
	fi

	source "$logger_script"

	check_dependencies

	# Discover directories
	if ! discover_png_directories "$INPUT_GLOBAL" "$OUTPUT_GLOBAL"; then
		log_error "No valid directories to process."
		exit 1
	fi

	# Process each directory
	for png_dir in "${PNG_DIRS_GLOBAL[@]}"; do
		staging_name=$(get_last_two_path_components "$png_dir")
		text_output_dir="$OUTPUT_GLOBAL/$(basename "$(dirname "$png_dir")")/text"

		if ! stage_png_directory "$png_dir" "$staging_name" "$text_output_dir"; then
			log_error "Failed to process directory: $png_dir"
			continue
		fi
	done

	log_success "png_to_text: All jobs completed."
}

# --- GLOBALS ---
declare -a PNG_DIRS_GLOBAL=()

# --- RUN ---
main "$@"
