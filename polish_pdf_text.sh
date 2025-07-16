#!/usr/bin/env bash
# polish_pdf_text.sh - Multi-worker text polishing system
# Combines sequential pages (1+2+3, 4+5+6, etc.) into polished text files
# Validates text directory by comparing with PNG directory
# Processes incomplete directories with proper retry logic

set -euo pipefail

# --- Configuration ---
CONFIG_FILE="$HOME/Dev/book_expert/project.toml"
CURL_TIMEOUT=120

# --- Global Variables ---
declare OUTPUT_DIR="" WORKERS=0 TEMP_PATH="" \
	GOOGLE_API_KEY_VAR="" POLISH_MODEL="" \
	LOG_DIR="" LOG_FILE="" PROCESSING_DIR="" \
	FAILED_LOG="" MAX_API_RETRIES=0 RETRY_DELAY_SECONDS=0
declare -a pdf_dirs=()
declare cleanup_called=false

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
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $*" | tee -a "${LOG_FILE:-/dev/null}"
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

check_dependencies()
{
	local deps=("yq" "jq" "curl" "rsync" "mktemp" "nproc")
	for dep in "${deps[@]}"; do
		command -v "$dep" >/dev/null || {
			log "Dependency '$dep' is not installed."
			exit 1
		}
	done

	[[ -z ${GOOGLE_API_KEY_VAR:-} ]] && {
		log "GOOGLE_API_KEY_VAR not configured"
		exit 1
	}
	[[ -z ${!GOOGLE_API_KEY_VAR:-} ]] && {
		log "API key variable '$GOOGLE_API_KEY_VAR' not set"
		exit 1
	}
	[[ -z ${POLISH_MODEL:-} ]] && {
		log "POLISH_MODEL not set"
		exit 1
	}

	# Validate API endpoint
	local curl_error_file
	curl_error_file=$(mktemp -p "$TEMP_PATH" "curl_error.XXXXXX")

	local test_response
	test_response=$(curl --fail --silent --show-error -o /dev/null -w "%{http_code}" \
		-H "x-goog-api-key: ${!GOOGLE_API_KEY_VAR}" \
		-H "Content-Type: application/json" \
		-X POST -d '{"contents":[{"parts":[{"text":"Test"}]}]}' \
		--max-time 120 \
		"https://generativelanguage.googleapis.com/v1beta/models/$POLISH_MODEL:generateContent" \
		2>"$curl_error_file") || true

	if [[ $test_response -ne 200 ]]; then
		log "API validation failed with HTTP code $test_response"
		log "Curl error: $(cat "$curl_error_file")"
		rm -f "$curl_error_file"
		exit 1
	fi
	rm -f "$curl_error_file"
}

validate_polished_directory()
{
	local pdf_name="$1"
	local polished_dir="$OUTPUT_DIR/$pdf_name/polished"
	local text_dir="$OUTPUT_DIR/$pdf_name/text"
	local png_dir="$OUTPUT_DIR/$pdf_name/png"

	[[ ! -d $text_dir || ! -d $png_dir ]] && {
		log "Skipping '$pdf_name': Missing 'text' or 'png' directory"
		return 1
	}

	local text_count png_count
	text_count=$(find "$text_dir" -name "*.txt" -type f | wc -l)
	png_count=$(find "$png_dir" -name "*.png" -type f | wc -l)

	# Check PNG/text count difference
	local max_diff
	max_diff=$(get_config "settings.max_png_text_diff" "3")
	local diff=$((png_count > text_count ? png_count - text_count : text_count - png_count))
	[[ $diff -gt $max_diff ]] && {
		log "Skipping '$pdf_name': PNG/text count difference ($diff) exceeds max ($max_diff)"
		return 1
	}

	mkdir -p "$polished_dir"
	local polished_count
	polished_count=$(find "$polished_dir" -name "polished_*.txt" -type f | wc -l)

	[[ $png_count -lt 1 ]] && {
		log "Skipping '$pdf_name': No PNG files found"
		return 1
	}

	# Calculate expected polished files
	local expected_polished=$(((png_count + 2) / 3)) # Ceiling division
	local polish_diff=$((polished_count > expected_polished ? polished_count - expected_polished : expected_polished - polished_count))

	[[ $polish_diff -le 3 ]] && {
		log "Directory '$pdf_name' complete: $polished_count/$expected_polished polished files"
		return 1
	}

	log "Processing '$pdf_name': PNG=$png_count, Polished=$polished_count/$expected_polished"
	return 0
}

get_pdf_names()
{
	local -a text_files=()
	mapfile -d '' -t text_files < <(find "$OUTPUT_DIR" -path "*/text/*.txt" -type f -print0)
	[[ ${#text_files[@]} -eq 0 ]] && {
		log "No text files found"
		exit 1
	}

	local -A unique_pdfs=()
	for text_file in "${text_files[@]}"; do
		local pdf_name
		pdf_name=$(basename "$(dirname "$(dirname "$text_file")")")
		[[ $pdf_name != "." && $pdf_name != ".." ]] && unique_pdfs["$pdf_name"]=1
	done
	pdf_dirs=("${!unique_pdfs[@]}")
}

copy_text_for_processing()
{
	local -a pdfs_to_copy=("$@")
	for pdf_name in "${pdfs_to_copy[@]}"; do
		local source_text_dir="$OUTPUT_DIR/$pdf_name/text"
		local dest_text_dir="$PROCESSING_DIR/$pdf_name/text"
		mkdir -p "$dest_text_dir"
		rsync -a --quiet "$source_text_dir/" "$dest_text_dir/" || {
			log "Failed to copy text files for PDF: $pdf_name"
			exit 1
		}
	done
}

call_api()
{
	local payload_file="$1"
	local response_file
	response_file=$(mktemp -p "$TEMP_PATH" "api_response.XXXXXX")

	local curl_error_file
	curl_error_file=$(mktemp -p "$TEMP_PATH" "curl_error.XXXXXX")

	local http_code
	http_code=$(curl --fail --silent --show-error -w "%{http_code}" -o "$response_file" \
		-H "x-goog-api-key: ${!GOOGLE_API_KEY_VAR}" \
		-H "Content-Type: application/json" \
		-X POST -d @"$payload_file" \
		--max-time "$CURL_TIMEOUT" \
		"https://generativelanguage.googleapis.com/v1beta/models/$POLISH_MODEL:generateContent" \
		2>"$curl_error_file") || true

	if [[ $http_code -ne 200 || ! -s $response_file ]]; then
		log "API call failed with HTTP code: $http_code"
		log "Curl error: $(cat "$curl_error_file")"
		rm -f "$response_file" "$curl_error_file"
		return 1
	fi
	rm -f "$curl_error_file"

	local content
	content=$(jq -r '.candidates[0].content.parts[0].text // empty' "$response_file" 2>/dev/null)
	[[ -z $content || $content == "null" ]] && {
		log "Failed to extract content from API response"
		rm -f "$response_file"
		return 1
	}

	echo "$content" >"$response_file"
	echo "$response_file"
}

process_text_group()
{
	local first_file="$1"
	local second_file="$2"
	local third_file="$3"
	local output_index="$4"
	local pdf_name final_output_file temp_output_file

	pdf_name=$(basename "$(dirname "$(dirname "$first_file")")")
	final_output_file="$OUTPUT_DIR/$pdf_name/polished/polished_$output_index.txt"
	temp_output_file="$final_output_file.tmp.$$"

	mkdir -p "$OUTPUT_DIR/$pdf_name/polished"
	local lock_file="$final_output_file.lock"

	exec 9>"$lock_file"
	flock -n 9 || {
		log "Another process handling: $pdf_name/polished_$output_index.txt"
		exec 9>&-
		rm -f "$lock_file"
		return 0
	}

	[[ -s $final_output_file ]] && {
		log "Already completed: $pdf_name/polished_$output_index.txt"
		rm -f "$first_file" "$second_file" "$third_file"
		exec 9>&-
		rm -f "$lock_file"
		return 0
	}

	# Build file description
	local desc="$pdf_name: $(basename "$first_file")"
	[[ -n $second_file && $second_file != "EMPTY" ]] && desc="$desc + $(basename "$second_file")"
	[[ -n $third_file && $third_file != "EMPTY" ]] && desc="$desc + $(basename "$third_file")"
	log "Processing: $desc -> polished_$output_index.txt"

	# Combine text files
	local combined_text
	combined_text=$(cat "$first_file")
	[[ -n $second_file && $second_file != "EMPTY" ]] && combined_text="$combined_text\n\n$(cat "$second_file")"
	[[ -n $third_file && $third_file != "EMPTY" ]] && combined_text="$combined_text\n\n$(cat "$third_file")"

	local prompt="**********
GUIDELINES: You are an expert Ph.D STEM technical editor and educator, and writing specialist.
* Polish and refine the provided text for clarity, coherence, and professional presentation.
* Maintain all technical accuracy while improving readability and flow.
* Ensure the text flows naturally and is suitable for text-to-speech (TTS) narration.
* Fix any grammatical errors, awkward phrasing, or unclear expressions.
* Enhance transitions between concepts and improve overall narrative structure.
* Maintain the technical depth and educational value of the content.
* This is not an interactive chat; output must be standalone polished text without conversational elements.
* The text will be part of a larger technical collection, so ensure consistency in style and tone.
* Focus on creating engaging, accessible content for a Ph.D level technical audience.
* Remove any artifacts, redundancies, or formatting issues that would disrupt TTS narration.
* Provide only the polished and refined text, ready for final use.
* No chapter, page numbers or other invalid artifacts.
* Start and focus on the concepts as the main point
* This is not a summarization task, do not summarize the content.
* This is a educational content. You can add analogies, examples, and further the explanation to promote learning, you should be as technical as posible, while maintaining TTS narration flow.
**********
TEXT: $combined_text"

	local payload_file
	payload_file=$(mktemp -p "$TEMP_PATH" "api_payload.XXXXXX")
	jq -n --arg prompt "$prompt" '{ "contents": [{ "parts": [{ "text": $prompt }] }] }' >"$payload_file"

	# Retry logic for API calls
	local retry_count=0
	local api_response_file=""

	while [[ $retry_count -lt $MAX_API_RETRIES ]]; do
		if api_response_file=$(call_api "$payload_file"); then
			break
		fi
		((retry_count++))
		[[ $retry_count -lt $MAX_API_RETRIES ]] && {
			log "API retry $retry_count/$MAX_API_RETRIES for $pdf_name/polished_$output_index.txt"
			sleep "$RETRY_DELAY_SECONDS"
		}
	done

	rm -f "$payload_file"

	if [[ -z $api_response_file ]]; then
		log "API call failed after $MAX_API_RETRIES retries"
		record_failure "$first_file" "API call failed after retries"
		exec 9>&-
		rm -f "$lock_file"
		return 1
	fi

	local polished_text
	polished_text=$(cat "$api_response_file")
	rm -f "$api_response_file"

	[[ -z $polished_text ]] && {
		log "Empty polished text for $pdf_name/polished_$output_index.txt"
		record_failure "$first_file" "Empty polished text"
		exec 9>&-
		rm -f "$lock_file"
		return 1
	}

	if echo "$polished_text" >"$temp_output_file" && mv "$temp_output_file" "$final_output_file"; then
		log "Success: $pdf_name/polished_$output_index.txt"
		# Remove processed files only on success
		rm -f "$first_file"
		[[ -n $second_file && $second_file != "EMPTY" ]] && rm -f "$second_file"
		[[ -n $third_file && $third_file != "EMPTY" ]] && rm -f "$third_file"
		exec 9>&-
		rm -f "$lock_file"
		return 0
	else
		log "Failed to write output file: $final_output_file"
		record_failure "$first_file" "Failed to write output file"
		rm -f "$temp_output_file"
		exec 9>&-
		rm -f "$lock_file"
		return 1
	fi
}

process_worker_block()
{
	local worker_id="$1"
	shift
	local -a work_items=("$@")
	log "Worker $worker_id processing $((${#work_items[@]} / 4)) work items"

	for ((i = 0; i < ${#work_items[@]}; i += 4)); do
		local first_file="${work_items[i]}"
		local second_file="${work_items[i + 1]}"
		local third_file="${work_items[i + 2]}"
		local output_index="${work_items[i + 3]}"

		[[ $second_file == "EMPTY" ]] && second_file=""
		[[ $third_file == "EMPTY" ]] && third_file=""

		process_text_group "$first_file" "$second_file" "$third_file" "$output_index" ||
			log "Worker $worker_id: Failed to process group starting with '$first_file'"
	done

	log "Worker $worker_id finished"
}

build_work_queue()
{
	local -a pdfs_to_process=("$@")
	local -a work_items=()

	for pdf_name in "${pdfs_to_process[@]}"; do
		local -a text_files=()
		mapfile -d '' -t text_files < <(find "$PROCESSING_DIR/$pdf_name/text" -name "*.txt" -type f -print0 | sort -zV)
		[[ ${#text_files[@]} -eq 0 ]] && continue

		mkdir -p "$OUTPUT_DIR/$pdf_name/polished"

		local output_index=1
		local processed_text_files=0
		local text_count=${#text_files[@]}

		while [[ $processed_text_files -lt $text_count ]]; do
			local expected_polished_file="$OUTPUT_DIR/$pdf_name/polished/polished_$output_index.txt"

			if [[ -s $expected_polished_file ]]; then
				# Skip existing files and increment counters appropriately
				local remaining_files=$((text_count - processed_text_files))
				if [[ $remaining_files -ge 3 ]]; then
					processed_text_files=$((processed_text_files + 3))
				elif [[ $remaining_files -eq 2 ]]; then
					processed_text_files=$((processed_text_files + 2))
				else
					processed_text_files=$((processed_text_files + 1))
				fi
				((output_index++))
				continue
			fi

			# Create work item for missing polished file
			local first_file="${text_files[$processed_text_files]}"
			local second_file="EMPTY"
			local third_file="EMPTY"

			[[ $((processed_text_files + 1)) -lt $text_count ]] && second_file="${text_files[processed_text_files + 1]}"
			[[ $((processed_text_files + 2)) -lt $text_count ]] && third_file="${text_files[processed_text_files + 2]}"

			work_items+=("$first_file" "$second_file" "$third_file" "$output_index")

			# Update processed count based on actual files assigned
			if [[ $third_file != "EMPTY" ]]; then
				processed_text_files=$((processed_text_files + 3))
			elif [[ $second_file != "EMPTY" ]]; then
				processed_text_files=$((processed_text_files + 2))
			else
				processed_text_files=$((processed_text_files + 1))
			fi
			((output_index++))
		done
	done

	printf '%s\n' "${work_items[@]}"
}

run_parallel_processing()
{
	local -a work_items=("$@")
	[[ ${#work_items[@]} -eq 0 ]] && return 0

	[[ $((${#work_items[@]} % 4)) -ne 0 ]] && {
		log "Error: work_items array length not multiple of 4"
		exit 1
	}

	local item_count=$((${#work_items[@]} / 4))
	log "Processing $item_count work items with $WORKERS workers"

	local -a worker_pids=()
	local items_per_worker=$(((item_count + WORKERS - 1) / WORKERS))

	for ((i = 0; i < WORKERS; i++)); do
		local start_index=$((i * items_per_worker * 4))
		[[ $start_index -ge ${#work_items[@]} ]] && break

		local -a worker_items=("${work_items[@]:start_index:items_per_worker*4}")
		[[ ${#worker_items[@]} -gt 0 ]] && {
			process_worker_block "$i" "${worker_items[@]}" &
			worker_pids+=($!)
			[[ $i -lt $((WORKERS - 1)) && $((start_index + items_per_worker * 4)) -lt ${#work_items[@]} ]] && sleep 60
		}
	done

	for pid in "${worker_pids[@]}"; do
		wait "$pid" || log "Worker with PID $pid failed"
	done
}

cleanup_and_exit()
{
	local exit_code=$?
	[[ $cleanup_called == true ]] && return
	cleanup_called=true
	log "Cleaning up and exiting..."

	[[ -n ${TEMP_PATH:-} && -d $TEMP_PATH ]] && {
		find "$TEMP_PATH" -name "api_response*" -o -name "api_payload*" -o -name "curl_error*" -type f -delete 2>/dev/null || true
	}

	[[ -n ${OUTPUT_DIR:-} && -d $OUTPUT_DIR ]] && {
		find "$OUTPUT_DIR" -name "*.lock" -type f -delete 2>/dev/null || true
	}

	[[ -n ${FAILED_LOG:-} && -f "$FAILED_LOG.lock" ]] && rm -f "$FAILED_LOG.lock"

	log "Cleanup finished. Exiting with code $exit_code"
	exit "$exit_code"
}

setup_temp_dir()
{
	mkdir -p "$TEMP_PATH"
	PROCESSING_DIR=$(mktemp -d -p "$TEMP_PATH" "processing_text.XXXXXX") || {
		log "Failed to create temporary processing directory"
		exit 1
	}
	log "Created temporary processing directory: $PROCESSING_DIR"
}

main()
{
	# Load configuration
	OUTPUT_DIR=$(get_config "paths.output_dir")
	WORKERS=$(get_config "settings.workers")
	TEMP_PATH=$(get_config "processing_dir.polish_text")
	GOOGLE_API_KEY_VAR=$(get_config "google_api.api_key_variable")
	POLISH_MODEL=$(get_config "google_api.polish_model" "gemini-2.5-flash")
	LOG_DIR=$(get_config "logs_dir.polish_text")
	MAX_API_RETRIES=$(get_config "retry.max_retries" "5")
	RETRY_DELAY_SECONDS=$(get_config "retry.retry_delay_seconds" "5")
	FAILED_LOG="$LOG_DIR/failed_pages.log"

	# Adjust workers to available cores
	local core_count
	core_count=$(nproc)
	[[ $WORKERS -gt $core_count ]] && {
		log "Reducing worker count from $WORKERS to $core_count"
		WORKERS=$core_count
	}

	# Setup logging
	mkdir -p "$LOG_DIR"
	LOG_FILE="$LOG_DIR/log_$(date +'%Y%m%d_%H%M%S').log"
	touch "$LOG_FILE" "$FAILED_LOG"
	log "Script started. Log file: $LOG_FILE"

	trap 'cleanup_and_exit' EXIT INT TERM
	check_dependencies
	setup_temp_dir
	get_pdf_names

	# Find PDFs needing processing
	local -a pdfs_to_process=()
	for pdf_name in "${pdf_dirs[@]}"; do
		validate_polished_directory "$pdf_name" && pdfs_to_process+=("$pdf_name")
	done

	[[ ${#pdfs_to_process[@]} -eq 0 ]] && {
		log "All polished directories complete. No processing needed."
		return 0
	}

	log "Processing ${#pdfs_to_process[@]} PDFs"
	copy_text_for_processing "${pdfs_to_process[@]}"

	# Main processing loop - retry entire queue if needed
	local queue_retry_count=0
	local max_queue_retries=3

	while [[ $queue_retry_count -lt $max_queue_retries ]]; do
		local -a work_items=()
		mapfile -t work_items < <(build_work_queue "${pdfs_to_process[@]}")

		[[ ${#work_items[@]} -eq 0 ]] && {
			log "All processing completed successfully"
			break
		}

		local item_count=$((${#work_items[@]} / 4))
		log "Queue attempt $((queue_retry_count + 1))/$max_queue_retries: Processing $item_count work items"

		run_parallel_processing "${work_items[@]}"

		# Check remaining work
		local remaining_files
		remaining_files=$(find "$PROCESSING_DIR" -name "*.txt" -type f | wc -l)
		[[ $remaining_files -eq 0 ]] && {
			log "All processing completed successfully"
			break
		}

		log "Retrying $remaining_files unprocessed files after ${RETRY_DELAY_SECONDS}s delay"
		sleep "$RETRY_DELAY_SECONDS"
		((queue_retry_count++))
	done

	# Final status check
	local failed_count
	failed_count=$(find "$PROCESSING_DIR" -name "*.txt" -type f | wc -l)
	if [[ $failed_count -gt 0 ]]; then
		log "$failed_count files remain unprocessed after $max_queue_retries queue retries"
		return 1
	fi

	log "All processing completed successfully"
	return 0
}

main "$@"
