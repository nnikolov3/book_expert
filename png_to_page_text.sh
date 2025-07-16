#!/usr/bin/env bash
# png_to_page_text.sh
# Design: Niko Nikolov
# Code: Various LLMs
# Revision: Gemini
# ===============================================================================================
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
# COMMENTS SHOULD NOT BE REMOVED, INCONCISTENCIES SHOULD BE UPDATED WHEN DETECTED
# USE MARKDOWN WITHIN THE COMMENT BLOCKS FOR COMMENTS
# ===============================================================================================
set -euo pipefail

# --- Configuration ---
CONFIG_FILE="$HOME/Dev/book_expert/project.toml"
MAX_API_RETRIES=3
BASE_RETRY_DELAY=5

# --- Global Variables ---
declare OUTPUT_DIR="" WORKERS=0 TEMP_PATH="" \
	NVIDIA_API_URL="" NVIDIA_API_KEY_VAR="" TEXT_FIX_MODEL="" CONCEPT_MODEL="" \
	MAX_RETRIES=0 RETRY_DELAY_SECONDS=0 \
	LOG_DIR="" FAILED_LOG="" LOG_FILE="" \
	TESSERACT_LANG="eng+equ" MAX_CONCURRENT_API_CALLS=10
declare -a worker_pids=()
declare -a pdf_subdirs=()
declare cleanup_called=false

# Semaphore for API rate limiting
declare api_semaphore_dir=""

get_config()
{
	local key="$1"
	local default_value="${2:-}"
	local value
	value=$(yq -r ".${key} // \"\"" "$CONFIG_FILE") || {
		if [[ -n $default_value ]]; then
			echo "$default_value"
			return 0
		fi
		error "Failed to read configuration key '$key' from $CONFIG_FILE"
		exit 1
	}
	if [[ -z $value ]]; then
		if [[ -n $default_value ]]; then
			echo "$default_value"
			return 0
		fi
		error "Missing required configuration key '$key' in $CONFIG_FILE"
		exit 1
	fi
	echo "$value"
}

log()
{
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $*" | tee -a "${LOG_FILE:-/dev/null}"
}

error()
{
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >>"${LOG_FILE:-/dev/null}"
}

check_dependencies()
{
	local deps=("yq" "jq" "curl" "base64" "tesseract" "rsync" "mktemp" "nproc" "awk")
	for dep in "${deps[@]}"; do
		if ! command -v "$dep" >/dev/null; then
			error "'$dep' is not installed."
			exit 1
		fi
	done

	# Check if NVIDIA_API_KEY_VAR is set and then validate its value
	if [[ -z ${NVIDIA_API_KEY_VAR:-} ]]; then
		error "NVIDIA_API_KEY_VAR is not configured in $CONFIG_FILE."
		exit 1
	elif [[ -z ${!NVIDIA_API_KEY_VAR:-} ]]; then
		error "API key environment variable '$NVIDIA_API_KEY_VAR' is not set or is empty."
		exit 1
	fi

	# Validate other required variables
	if [[ -z ${TEXT_FIX_MODEL:-} ]]; then
		error "TEXT_FIX_MODEL is not set."
		exit 1
	fi

	if [[ -z ${CONCEPT_MODEL:-} ]]; then
		error "CONCEPT_MODEL is not set."
		exit 1
	fi
}

# Initialize API semaphore for rate limiting
init_api_semaphore()
{
	api_semaphore_dir=$(mktemp -d -p "$TEMP_PATH" "api_semaphore.XXXXXX") || {
		error "Failed to create API semaphore directory"
		exit 1
	}

	# Create semaphore files
	for ((i = 1; i <= MAX_CONCURRENT_API_CALLS; i++)); do
		touch "$api_semaphore_dir/slot_$i"
	done

	log "API semaphore initialized with $MAX_CONCURRENT_API_CALLS concurrent slots"
}

# Acquire API semaphore slot
acquire_api_slot()
{
	local slot_file
	while true; do
		for ((i = 1; i <= MAX_CONCURRENT_API_CALLS; i++)); do
			slot_file="$api_semaphore_dir/slot_$i"
			if (
				flock -n 9
				if [[ -f $slot_file ]]; then
					rm -f "$slot_file"
					echo "$i"
					return 0
				fi
				return 1
			) 9>"$slot_file.lock" 2>/dev/null; then
				return 0
			fi
		done
		sleep 0.1
	done
}

# Release API semaphore slot
release_api_slot()
{
	local slot_num="$1"
	local slot_file="$api_semaphore_dir/slot_$slot_num"
	touch "$slot_file"
	rm -f "$slot_file.lock"
}

# Extract text content from API response
extract_text_from_response()
{
	local response="$1"
	local content

	# Validate JSON first
	if ! echo "$response" | jq empty 2>/dev/null; then
		error "Invalid JSON response received"
		echo "$response" | head -c 500 >&2
		return 1
	fi

	# Check for API-level errors first
	if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
		local error_msg
		error_msg=$(echo "$response" | jq -r '.error.message // .error // "Unknown API error"')
		error "API returned error: $error_msg"
		return 1
	fi

	# Try to extract content from the response JSON
	content=$(echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

	if [[ -z $content || $content == "null" ]]; then
		# Try alternative JSON structures
		content=$(echo "$response" | jq -r '.content // .text // .response // empty' 2>/dev/null)
	fi

	if [[ -z $content || $content == "null" ]]; then
		error "Failed to extract content from API response"
		echo "$response" | jq . >&2 2>/dev/null || echo "$response" | head -c 500 >&2
		return 1
	fi

	echo "$content"
}

call_api()
{
	local payload_file="$1"
	local response_file
	response_file=$(mktemp)
	local http_code
	local slot_num

	# Acquire API rate limiting slot
	slot_num=$(acquire_api_slot)

	for ((i = 1; i <= MAX_API_RETRIES; i++)); do
		local current_delay=$((BASE_RETRY_DELAY * (2 ** (i - 1))))

		http_code=$(curl -sS -w "%{http_code}" --request POST \
			--url "$NVIDIA_API_URL" \
			--header "Authorization: Bearer ${!NVIDIA_API_KEY_VAR}" \
			--header "Content-Type: application/json" \
			--data-binary "@$payload_file" \
			--connect-timeout 30 \
			--max-time 300 \
			--retry 60 \
			-o "$response_file" 2>>"$LOG_FILE")

		# Success case
		if [[ $http_code -eq 200 && -s $response_file ]]; then
			# Validate JSON and check for API errors
			if jq empty <"$response_file" 2>/dev/null &&
				! jq -e '.error' "$response_file" >/dev/null 2>&1; then
				cat "$response_file"
				rm -f "$response_file"
				release_api_slot "$slot_num"
				sleep 30
				return 0
			fi
		fi

		# Log specific error types
		case $http_code in
		429) log "Rate limited (attempt $i/$MAX_API_RETRIES). Waiting ${current_delay}s..." ;;
		504) log "Gateway timeout (attempt $i/$MAX_API_RETRIES). Waiting ${current_delay}s..." ;;
		500 | 502 | 503) log "Server error $http_code (attempt $i/$MAX_API_RETRIES). Waiting ${current_delay}s..." ;;
		*) log "API call failed (attempt $i/$MAX_API_RETRIES) with HTTP code: $http_code. Waiting ${current_delay}s..." ;;
		esac

		# Don't sleep after the last attempt
		if [[ $i -lt $MAX_API_RETRIES ]]; then
			sleep "$current_delay"
		fi
	done

	error "API call failed after $MAX_API_RETRIES attempts. Last HTTP code: $http_code"
	if [[ -s $response_file ]]; then
		error "Last response saved to: $response_file"
		# Don't remove the file for debugging
	fi
	release_api_slot "$slot_num"
	return 1
}

validate_text_directory()
{
	local pdf_name="$1"
	local text_dir="$OUTPUT_DIR/$pdf_name/text"
	local png_dir="$OUTPUT_DIR/$pdf_name/png"

	if [[ ! -d $text_dir ]]; then return 1; fi
	if [[ ! -d $png_dir ]]; then return 1; fi

	# Optimize by using single find command with counting
	local png_count text_count
	png_count=$(find "$png_dir" -name "*.png" -type f | wc -l)
	text_count=$(find "$text_dir" -name "*.txt" -type f | wc -l)

	if [[ $text_count -ne $png_count ]]; then
		log "Incomplete text directory for '$pdf_name'. PNG files: $png_count, Text files: $text_count. Reprocessing."
		rm -rf "$text_dir"
		return 1
	fi
	return 0
}

get_pdf_subdirs()
{
	local -a dirs=()
	mapfile -d '' -t dirs < <(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -zV)
	if [[ ${#dirs[@]} -eq 0 ]]; then
		error "No PDF subdirectories found in $OUTPUT_DIR"
		exit 1
	fi

	for dir in "${dirs[@]}"; do
		pdf_subdirs+=("$(basename "$dir")")
	done
}

run_tesseract_ocr()
{
	local image_path="$1"
	tesseract "$image_path" stdout -l "$TESSERACT_LANG" 2>>"$LOG_FILE"
}

correct_text()
{
	local raw_text="$1"
	local prompt="**********
GUIDELINES: You are an expert STEM scientist with deep domain knowledge.
* Correct OCR errors in the provided text, fixing grammar and formatting for clarity and readability.
* Expand and explain technical terms, code blocks, data, jargon, and abbreviations to ensure accessibility for a Masters-level audience.
* This is not an interactive chat; output must be standalone text without conversational elements like introductions or confirmations.
* The text will be part of a larger collection, narrated via text-to-speech (TTS) for accessibility, requiring clear and natural flow.
* If the text contains excessive garbage characters, focus only on coherent sections and discard the rest to maintain quality.
* Do not include notes, feedback, or confirmations in the output, as they disrupt the narration flow.
* Provide only the corrected and formatted text, suitable for TTS narration.
**********
	TEXT: $raw_text"

	local payload_file response
	payload_file=$(mktemp) || {
		error "Failed to create temporary payload file"
		return 1
	}

	jq -n --arg model "$TEXT_FIX_MODEL" --arg prompt "$prompt" \
		'{model: $model, messages: [{"role": "user", "content": $prompt}], max_tokens: 8192, temperature: 0.3, top_p: 0.5, stream: false}' >"$payload_file" || {
		error "Failed to create JSON payload"
		rm -f "$payload_file"
		return 1
	}

	if response=$(call_api "$payload_file"); then
		rm -f "$payload_file"
		extract_text_from_response "$response"
	else
		rm -f "$payload_file"
		return 1
	fi
}

extract_concepts()
{
	local image_path="$1"
	local corrected_text="$2"
	local b64_file prompt_file payload_file response
	b64_file=$(mktemp) || {
		error "Failed to create base64 temp file"
		return 1
	}
	prompt_file=$(mktemp) || {
		error "Failed to create prompt temp file"
		rm -f "$b64_file"
		return 1
	}
	payload_file=$(mktemp) || {
		error "Failed to create payload temp file"
		rm -f "$b64_file" "$prompt_file"
		return 1
	}

	base64 -w 0 "$image_path" >"$b64_file" || {
		error "Failed to encode image to base64"
		rm -f "$b64_file" "$prompt_file" "$payload_file"
		return 1
	}

	local new_prompt="**********
GUIDELINES: You are a STEM professor with deep expertise in technical domains.
* Identify and explain concepts and technical information from a page of a technical document, focusing on clarity and insight.
* Write as if contributing to a technical book, in an engaging, accessible style for a Masters student.
* This is not an interactive chat; output must exclude conversational elements like introductions or summaries.
* The text will be part of a larger collection, narrated via TTS for accessibility, requiring clear and natural flow.
* Ensure explanations are insightful, reflecting a deep understanding of the concepts for educational value.
* Avoid summaries, conclusions, or introductions to ensure seamless integration into the collection.
* Do not reference 'text', 'page', 'image', or 'picture'; focus directly on the concepts as the main subject.
* Start with the concepts as the primary focus for narrative coherence. It should be technical and detailed
**********
	TEXT: $corrected_text"

	printf "%s" "$new_prompt" >"$prompt_file"

	jq -n --arg model "$CONCEPT_MODEL" --rawfile prompt "$prompt_file" --rawfile b64 "$b64_file" \
		'{model: $model, messages: [{"role": "user", "content": [{"type": "text", "text": $prompt}, {"type": "image_url", "image_url": {"url": ("data:image/png;base64," + $b64)}}]}], max_tokens: 8192, temperature: 0.5, top_p: 0.5, stream: false}' >"$payload_file" || {
		error "Failed to create concept extraction payload"
		rm -f "$b64_file" "$prompt_file" "$payload_file"
		return 1
	}

	if response=$(call_api "$payload_file"); then
		rm -f "$b64_file" "$prompt_file" "$payload_file"
		extract_text_from_response "$response"
	else
		rm -f "$b64_file" "$prompt_file" "$payload_file"
		return 1
	fi
}

record_failure()
{
	local file_path="$1"
	local error_msg="${2:-Unknown error}"
	(
		flock -x 201
		echo "$file_path" >>"$FAILED_LOG"
		echo "[$(date +'%Y-%m-%d %H:%M:%S')] FAILED: $file_path - $error_msg" >>"$LOG_FILE"
	) 201>>"$FAILED_LOG.lock"
}

process_image()
{
	local image_file="$1"
	local image_name pdf_name final_text_dir final_output_file temp_output_file
	image_name=$(basename "$image_file")
	# Navigate up two directories from image_file to get PDF name
	pdf_name=$(basename "$(dirname "$(dirname "$image_file")")")
	final_text_dir="$OUTPUT_DIR/$pdf_name/text"
	final_output_file="$final_text_dir/${image_name%.png}.txt"
	temp_output_file="$final_output_file.tmp.$$"

	mkdir -p "$final_text_dir"

	# Create lock file to prevent race conditions
	local lock_file="$final_output_file.lock"

	# Use exec to properly handle file descriptor
	exec 9>"$lock_file"

	if ! flock -n 9; then
		log "Another process is handling: $pdf_name/$image_name"
		exec 9>&-
		return 0
	fi

	# Double-check after acquiring lock
	if [[ -s $final_output_file ]]; then
		log "File completed by another process: $pdf_name/$image_name"
		exec 9>&-
		rm -f "$lock_file"
		return 0
	fi

	log "--- Processing: $pdf_name/$image_name ---"

	local raw_text corrected_text concepts

	# OCR processing with error handling
	if ! raw_text=$(run_tesseract_ocr "$image_file"); then
		record_failure "$image_file" "OCR failed"
		exec 9>&-
		rm -f "$lock_file"
		return 1
	fi

	if [[ -z $raw_text ]]; then
		record_failure "$image_file" "OCR produced no text"
		exec 9>&-
		rm -f "$lock_file"
		return 1
	fi

	# Text correction with error handling
	if ! corrected_text=$(correct_text "$raw_text"); then
		record_failure "$image_file" "Text correction failed"
		exec 9>&-
		rm -f "$lock_file"
		return 1
	fi

	if [[ -z $corrected_text ]]; then
		record_failure "$image_file" "Text correction produced no output"
		exec 9>&-
		rm -f "$lock_file"
		return 1
	fi

	# Concept extraction with error handling
	if ! concepts=$(extract_concepts "$image_file" "$corrected_text"); then
		record_failure "$image_file" "Concept extraction failed"
		exec 9>&-
		rm -f "$lock_file"
		return 1
	fi

	if [[ -z $concepts ]]; then
		record_failure "$image_file" "Concept extraction produced no output"
		exec 9>&-
		rm -f "$lock_file"
		return 1
	fi

	# Create final merged text with clear separation
	{
		echo "$corrected_text"
		echo ""
		echo "$concepts"
	} >"$temp_output_file"

	if mv "$temp_output_file" "$final_output_file"; then
		log "--- Success: $pdf_name/$image_name ---"
		exec 9>&-
		rm -f "$lock_file"
		return 0
	else
		rm -f "$temp_output_file"
		record_failure "$image_file" "Failed to write final output"
		exec 9>&-
		rm -f "$lock_file"
		return 1
	fi
}

process_worker_block()
{
	local worker_id="$1"
	shift
	local -a files_for_worker=("$@")
	log "Worker $worker_id starting with ${#files_for_worker[@]} files."

	for file in "${files_for_worker[@]}"; do
		if ! process_image "$file"; then
			error "Worker $worker_id: Failed to process '$file'"
		fi
	done

	log "Worker $worker_id finished."
}

run_parallel_processing()
{
	local -a files_to_process=("$@")
	if [[ ${#files_to_process[@]} -eq 0 ]]; then return 0; fi

	log "Distributing ${#files_to_process[@]} files to $WORKERS workers."

	worker_pids=()
	local total_files=${#files_to_process[@]}
	local files_per_worker=$(((total_files + WORKERS - 1) / WORKERS))
	local worker_delay=120

	for ((i = 0; i < WORKERS; i++)); do
		local start_index=$((i * files_per_worker))
		if ((start_index >= total_files)); then break; fi

		local -a worker_files=("${files_to_process[@]:start_index:files_per_worker}")

		if [[ ${#worker_files[@]} -gt 0 ]]; then
			process_worker_block "$i" "${worker_files[@]}" &
			worker_pids+=($!)

			if [[ $i -lt $((WORKERS - 1)) && $((start_index + files_per_worker)) -lt $total_files ]]; then
				sleep "$worker_delay"
			fi
		fi
	done

	for pid in "${worker_pids[@]}"; do
		wait "$pid" || error "Worker with PID $pid failed."
	done
	worker_pids=()
}

cleanup_and_exit()
{
	local exit_code=$?
	if [[ $cleanup_called == true ]]; then return; fi
	cleanup_called=true
	log "Cleaning up and exiting..."

	if [[ ${#worker_pids[@]} -gt 0 ]]; then
		log "Terminating ${#worker_pids[@]} worker processes..."
		for pid in "${worker_pids[@]}"; do
			if [[ $pid -gt 1 ]] && kill -0 "$pid" 2>/dev/null; then
				kill "$pid" 2>/dev/null || true
			fi
		done

		sleep 2

		for pid in "${worker_pids[@]}"; do
			if [[ $pid -gt 1 ]] && kill -0 "$pid" 2>/dev/null; then
				log "Force killing worker $pid..."
				kill -9 "$pid" 2>/dev/null || true
			fi
		done
	fi

	# Clean up API semaphore
	if [[ -n ${api_semaphore_dir:-} && -d $api_semaphore_dir && $api_semaphore_dir == "$TEMP_PATH/api_semaphore."* ]]; then
		log "Removing API semaphore directory: $api_semaphore_dir"
		rm -rf "$api_semaphore_dir"
	fi

	# Clean up any remaining lock files
	if [[ -n ${OUTPUT_DIR:-} && -d $OUTPUT_DIR ]]; then
		find "$OUTPUT_DIR" -name "*.lock" -type f -delete 2>/dev/null || true
	fi

	rm -f "${FAILED_LOG}.lock"
	log "Cleanup finished. Exiting with code $exit_code."
	exit "$exit_code"
}

main()
{
	# Load configuration with validation
	OUTPUT_DIR=$(get_config "paths.output_dir")
	WORKERS=$(get_config "settings.workers")
	TEMP_PATH=$(get_config "processing_dir.png_to_text")
	NVIDIA_API_URL=$(get_config "nvidia_api.url")
	NVIDIA_API_KEY_VAR=$(get_config "nvidia_api.api_key_variable")
	TEXT_FIX_MODEL=$(get_config "nvidia_api.text_fix_model")
	CONCEPT_MODEL=$(get_config "nvidia_api.concept_model")
	MAX_RETRIES=$(get_config "retry.max_retries")
	RETRY_DELAY_SECONDS=$(get_config "retry.retry_delay_seconds")
	LOG_DIR=$(get_config "logs_dir.png_to_text")
	mkdir -p "$TEMP_PATH"

	# Make tesseract language configurable
	TESSERACT_LANG=$(get_config "tesseract.language" "eng+equ")

	# Make API concurrency configurable
	MAX_CONCURRENT_API_CALLS=$(get_config "nvidia_api.max_concurrent_calls" "10")

	# Validate worker count
	local core_count
	core_count=$(nproc) || {
		error "Failed to determine number of CPU cores."
		exit 1
	}
	if [[ $WORKERS -gt $core_count ]]; then
		log "Reducing worker count from $WORKERS to $core_count (available cores)"
		WORKERS=$core_count
	fi

	mkdir -p "$LOG_DIR" || {
		error "Failed to create log directory: $LOG_DIR"
		exit 1
	}
	LOG_FILE="$LOG_DIR/log_$(date +'%Y%m%d_%H%M%S').log"
	FAILED_LOG="$LOG_DIR/failed_pages.log"
	touch "$LOG_FILE" "$FAILED_LOG" || {
		error "Failed to create log files."
		exit 1
	}
	log "Script started. Log file: $LOG_FILE"

	trap 'cleanup_and_exit' EXIT INT TERM
	check_dependencies
	init_api_semaphore

	get_pdf_subdirs

	local -a all_files_to_process=()
	for pdf_name in "${pdf_subdirs[@]}"; do
		log "Checking document: $pdf_name"
		if ! validate_text_directory "$pdf_name"; then
			log "Document '$pdf_name' requires processing."
			local pdf_png_dir="$OUTPUT_DIR/$pdf_name/png"
			if [[ -d $pdf_png_dir ]]; then
				mapfile -d '' -t pdf_files < <(find "$pdf_png_dir" -name "*.png" -type f -print0 | sort -zV)
				all_files_to_process+=("${pdf_files[@]}")
			else
				error "PNG directory not found for '$pdf_name' at '$pdf_png_dir'"
			fi
		else
			log "Document '$pdf_name' is already complete. Skipping."
		fi
	done

	if [[ ${#all_files_to_process[@]} -eq 0 ]]; then
		log "All documents are complete. No new pages to process."
		return 0
	fi

	log "Found ${#all_files_to_process[@]} total pages to process across all documents."
	run_parallel_processing "${all_files_to_process[@]}"

	# Retry logic with exponential backoff for any failed pages
	local retry_attempt=0
	local retry_delay="$RETRY_DELAY_SECONDS"

	while [[ $retry_attempt -le $MAX_RETRIES && -s $FAILED_LOG ]]; do
		local -a failed_files
		mapfile -t failed_files <"$FAILED_LOG"
		: >"$FAILED_LOG" # Clear the log for the next retry run

		log "--- Retrying ${#failed_files[@]} failed pages (Attempt $retry_attempt/$MAX_RETRIES) after ${retry_delay}s delay..."
		sleep "$retry_delay"
		run_parallel_processing "${failed_files[@]}"

		retry_delay=$((retry_delay * 2))
		((retry_attempt++))
	done

	if [[ -s $FAILED_LOG ]]; then
		local failed_count
		failed_count=$(wc -l <"$FAILED_LOG")
		error "$failed_count pages failed after all retries. See '$FAILED_LOG' for details."
		return 1
	fi

	log "All processing jobs completed successfully."
	return 0
}

# Entry point for the script
main "$@"
