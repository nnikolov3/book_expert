#!/usr/bin/env bash
# polish_pdf_text.sh - Serial text polishing system using Cerebras API
# Combines sequential pages (1+2+3, 4+5+6, etc.) into polished text files
# Validates text directory by comparing with PNG directory
# Processes incomplete directories with proper retry logic

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

# --- Configuration ---
declare CONFIG_FILE="$HOME/Dev/book_expert/project.toml"
declare CURL_TIMEOUT=120
declare RATE_LIMIT_SLEEP=60

# --- Global Variables ---
declare OUTPUT_DIR=""
declare PROCESSING_DIR=""
declare CEREBRAS_API_KEY_VAR=""
declare POLISH_MODEL=""
declare LOG_DIR=""
declare LOG_FILE=""
declare INPUT_DIR=""
declare TEXT_DIRS_GLOBAL=""
declare FAILED_LOG=""
declare MAX_API_RETRIES=0
declare RETRY_DELAY_SECONDS=0
declare MAX_TOKENS=0
declare TEMPERATURE=0.0
declare TOP_P=0.0

declare -a RESULT_ARRAY=()

print_line()
{
	echo "======================================================================="
}

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

get_config()
{
	local key="$1"
	local default_value="${2:-}"
	local value=""
	local yq_output=""

	yq_output=$(yq -r ".${key} // \"\"" "$CONFIG_FILE")
	local yq_exit=$?

	if [[ $yq_exit -ne 0 ]]; then
		if [[ -n $default_value ]]; then
			echo "$default_value"
			return 0
		fi
		log_error "Failed to read configuration key '$key' from $CONFIG_FILE"
		return 1
	fi

	value="$yq_output"

	if [[ -z $value ]] && [[ -n $default_value ]]; then
		echo "$default_value"
		return 0
	fi

	if [[ -z $value ]]; then
		log_error "Missing required configuration key '$key' in $CONFIG_FILE"
		return 1
	fi

	echo "$value"
}

check_dependencies()
{
	local deps=("yq" "jq" "curl" "rsync" "mktemp")
	local dep=""
	local cmd_output=""

	for dep in "${deps[@]}"; do
		cmd_output=$(command -v "$dep")
		if [[ -z $cmd_output ]]; then
			log_error "Dependency '$dep' is not installed."
			exit 1
		fi
	done

	if [[ -z ${CEREBRAS_API_KEY_VAR:-} ]]; then
		log_error "CEREBRAS_API_KEY_VAR not configured"
		exit 1
	fi

	if [[ -z ${!CEREBRAS_API_KEY_VAR:-} ]]; then
		log_error "API key variable '$CEREBRAS_API_KEY_VAR' not set"
		exit 1
	fi

	if [[ -z ${POLISH_MODEL:-} ]]; then
		log_error "POLISH_MODEL not set"
		exit 1
	fi

	log_success "Dependencies verified"
	return 0
}

call_api_cerebras()
{
	local payload_file="$1"
	local response_file=""
	local curl_error_file=""
	local http_code=""
	local curl_output=""
	local content=""
	local full_response=""

	response_file=$(mktemp -p "$PROCESSING_DIR" "api_response.XXXXXX")
	curl_error_file=$(mktemp -p "$PROCESSING_DIR" "curl_error.XXXXXX")

	curl_output=$(curl --fail --silent --show-error -w "%{http_code}" -o "$response_file" \
		--request POST \
		--url "https://api.cerebras.ai/v1/chat/completions" \
		-H "Content-Type: application/json" \
		-H "Authorization: Bearer ${!CEREBRAS_API_KEY_VAR}" \
		-d @"$payload_file" \
		--max-time "$CURL_TIMEOUT")
	local curl_exit="$?"

	http_code="$curl_output"

	# Handle 429 rate limit specifically
	if [[ $http_code -eq 429 ]]; then
		log_warn "Rate limit hit (429), sleeping for $RATE_LIMIT_SLEEP seconds"
		sleep "$RATE_LIMIT_SLEEP"
		rm -f "$response_file" "$curl_error_file"
		return 1
	fi

	if [[ $curl_exit -ne 0 ]] || [[ $http_code -ne 200 ]] || [[ ! -s $response_file ]]; then
		log_error "Cerebras API call failed with HTTP code: $http_code"
		if [[ -f $curl_error_file ]]; then
			log_error "Curl error: $(cat "$curl_error_file")"
		fi
		if [[ -f $response_file ]]; then
			log_error "Response file content: $(cat "$response_file")"
		fi
		rm -f "$response_file" "$curl_error_file"
		return 1
	fi
	rm -f "$curl_error_file"

	# Check if this is a streaming response or regular response
	full_response=$(<"$response_file")

	# Handle streaming response (multiple JSON objects separated by newlines)
	if echo "$full_response" | head -1 | jq -e '.choices[0].delta' >/dev/null 2>&1; then
		# Streaming response - concatenate all content from delta messages
		content=""
		while IFS= read -r line; do
			if [[ -n $line ]]; then
				local delta_content=""
				delta_content=$(echo "$line" | jq -r '.choices[0].delta.content // empty' 2>/dev/null || echo "")
				if [[ -n $delta_content ]] && [[ $delta_content != "null" ]]; then
					content="$content$delta_content"
				fi
			fi
		done <"$full_response"
	else
		# Regular response format
		content=$(echo "$full_response" | jq -r '.choices[0].message.content // empty')
	fi

	if [[ -z $content ]] || [[ $content == "null" ]]; then
		log_error "Failed to extract content from Cerebras API response"
		log_error "Full API response: $full_response"
		rm -f "$response_file"
		return 1
	fi

	# Remove <think> tags and their content
	content=$(echo "$content" | sed '/<think>/,/<\/think>/d')

	echo "$content" >"$response_file"
	echo "$response_file"
}

get_next_start_index()
{
	local storage_dir="$1"
	local max_index=-1
	local polished_file=""
	local index=""

	if [[ ! -d $storage_dir ]]; then
		echo "0"
		return 0
	fi

	while IFS= read -r -d '' polished_file; do
		if [[ $polished_file =~ polished_([0-9]+)\.txt$ ]]; then
			index="${BASH_REMATCH[1]}"
			if [[ $index -gt $max_index ]]; then
				max_index=$index
			fi
		fi
	done < <(find "$storage_dir" -name "polished_*.txt" -print0)

	if [[ $max_index -eq -1 ]]; then
		echo "0"
	else
		echo $((max_index + 1))
	fi
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
	local polished_file=""
	local combined_text=""
	local system_prompt=""
	local user_prompt=""
	local payload_file=""
	local retry_count=0
	local api_response_file=""
	local polished_text=""
	local output_file_path=""

	polished_file="polished_${output_index}.txt"

	if [[ -n $second_file ]] && [[ $second_file != "" ]]; then
		desc="$desc + $(basename "$second_file")"
	fi

	if [[ -n $third_file ]] && [[ $third_file != "" ]]; then
		desc="$desc + $(basename "$third_file")"
	fi

	log_info "Processing: $desc -> $polished_file"

	# Combine text files
	combined_text=$(<"$first_file")
	if [[ -n $second_file ]] && [[ $second_file != "" ]]; then
		combined_text="$combined_text\n\n$(<"$second_file")"
	fi
	if [[ -n $third_file ]] && [[ $third_file != "" ]]; then
		combined_text="$combined_text\n\n$(<"$third_file")"
	fi

	system_prompt="You are an expert Ph.D STEM technical editor, educator, researcher, and writing specialist. 
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
12. No page numbers or other invalid artifacts.
13. Start and focus on the concepts as the main point. 
14. This is not a summarization task, do not summarize the content.  
15. This is a educational content. 
16. You can add analogies, examples, and further the explanation to promote learning.  
17. Do not dumb down the content. 
18. Maintain TTS narration flow using diverse vocabulary.  
19. Write everything in plain text paragraphs, no emphasis, headers, bold, italic, no conversational elements.  
20. Code, graphs, diagrams and similar, should be described word for word as being explained to someone who can't seem them. 
21. If anything needs emphasizing, describe it via words.  i.e., 'this is very important to note'
22. Avoid using directrly technical examples, formulas, assembly instructions, instead describe it in words.
Example, 'E=mc^2', 'Energy is equal to mass and speed of light squared.', '1 + 1 = 2', one plus one equals two. There should no special characters in the response. For code, if '(a > 0){ printf(\"Hello\")}', 'the C code checks if a is larger than zero, if it is larger, then it prints Hello'
23. If there are problems (textbook type problems ) solve them, explain the solution.  'Problem 1: Problem description', 'Problem 1 Solution: To solve this problem.'
24. If you detect information which is outdated, mention the update, and how it is as of today.
25. Do not include any thinking tags or meta-commentary in your response. /no_think"

	user_prompt="TEXT TO POLISH AND RETURN ONLY THE POLISHED TEXT: $combined_text"

	payload_file=$(mktemp -p "$PROCESSING_DIR" "api_payload.XXXXXX")

	jq -n \
		--arg model "$POLISH_MODEL" \
		--argjson max_tokens "$MAX_TOKENS" \
		--argjson temperature "$TEMPERATURE" \
		--argjson top_p "$TOP_P" \
		--arg system_content "$system_prompt" \
		--arg user_content "${user_prompt} /no_think" \
		'{
  "model": $model,
  "stream": false,
  "max_tokens": $max_tokens,
  "temperature": $temperature,
  "top_p": $top_p,
  "messages": [
    {
      "role": "system",
      "content": $system_content
    },
    {
      "role": "user", 
      "content": $user_content
    }
  ]
}' >"$payload_file"

	# Retry logic for API calls
	retry_count=0
	api_response_file=""

	while [[ $retry_count -lt $MAX_API_RETRIES ]]; do
		api_response_file=$(call_api_cerebras "$payload_file")
		local call_exit=$?
		if [[ $call_exit -eq 0 ]]; then
			sleep 10
			break
		fi
		retry_count=$((retry_count + 1))
		if [[ $retry_count -lt $MAX_API_RETRIES ]]; then
			log_warn "API retry $retry_count/$MAX_API_RETRIES for $polished_file"
			sleep "$RETRY_DELAY_SECONDS"
		fi
	done

	rm -f "$payload_file"

	if [[ -z $api_response_file ]]; then
		log_error "API call failed after $MAX_API_RETRIES retries for $polished_file"
		return 1
	fi

	# Read the polished content from the API response file
	polished_text=$(<"$api_response_file")
	rm -f "$api_response_file"

	if [[ -z $polished_text ]]; then
		log_error "Empty polished text received for $polished_file"
		return 1
	fi

	# Save the polished text to the output file
	output_file_path="${storage_dir}/${polished_file}"
	echo "$polished_text" >"$output_file_path"
	local write_exit
	write_exit="$?"

	if [[ $write_exit -eq 0 ]]; then
		log_success "Saved $output_file_path"
		return 0
	else
		log_error "Failed to save polished text to $output_file_path"
		return 1
	fi
}

polish_text()
{
	local storage_dir="$1"
	local total_files=${#RESULT_ARRAY[@]}
	local start_index=0
	local output_index=0
	local i=0
	local first_file=""
	local second_file=""
	local third_file=""
	local candidate=""
	local end_file=0
	local group_result=0

	if [[ $total_files -eq 0 ]]; then
		log_error "No text files to process"
		return 1
	fi

	start_index=$(get_next_start_index "$storage_dir")

	if [[ $start_index -gt 0 ]]; then
		log_info "Resuming from polished index $start_index"
	fi

	log_info "Processing $total_files text files in groups of 3"
	print_line

	# Calculate starting file position based on start_index
	i=$((start_index * 3))
	output_index=$start_index

	# Process files in groups of 3 starting from calculated position
	for (( ; i < total_files; i += 3)); do
		first_file="${RESULT_ARRAY[i]}"
		second_file=""
		third_file=""

		# Check if files exist and are readable
		if [[ ! -r $first_file ]]; then
			log_error "Cannot read file: $first_file"
			return 1
		fi

		# Check if second file exists
		if [[ $((i + 1)) -lt $total_files ]]; then
			candidate="${RESULT_ARRAY[$((i + 1))]}"
			if [[ -r $candidate ]]; then
				second_file="$candidate"
			fi
		fi

		# Check if third file exists
		if [[ $((i + 2)) -lt $total_files ]]; then
			candidate="${RESULT_ARRAY[$((i + 2))]}"
			if [[ -r $candidate ]]; then
				third_file="$candidate"
			fi
		fi

		if [[ $((i + 3)) -le $total_files ]]; then
			end_file=$((i + 3))
		else
			end_file=$total_files
		fi

		log_info "Processing group $output_index: files $((i + 1))-$end_file of $total_files"
		print_line

		# Call existing process_text_group function
		process_text_group "$first_file" "$second_file" "$third_file" "$output_index" "$storage_dir"
		group_result=$?

		if [[ $group_result -eq 0 ]]; then
			log_success "Processed polished_$output_index"
		else
			log_warn "Failed to process group $output_index"
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
	local safe_name=""
	local temp_dir=""
	local rsync_output=""
	local rsync_exit=0
	local text_array=()
	local file=""

	# Reset
	RESULT_ARRAY=()

	# Input validation
	if [[ -z $text_directory ]] || [[ ! -d $text_directory ]]; then
		log_error "Invalid text directory: $text_directory"
		return 1
	fi

	if [[ -z $processing_text_dir ]]; then
		log_error "Processing text directory not specified"
		return 1
	fi

	if [[ -z $storage_dir ]] || [[ ! -d $storage_dir ]]; then
		log_error "Invalid storage directory: $storage_dir"
		return 1
	fi

	# Check if PROCESSING_DIR is defined
	if [[ -z $PROCESSING_DIR ]]; then
		log_error "PROCESSING_DIR environment variable not set"
		return 1
	fi

	log_info "STORAGE $storage_dir"
	print_line

	# Create safe directory name
	safe_name=$(echo "$processing_text_dir" | tr '/' '_')

	log_info "Removing old directories with the same base directory"
	rm -rf "${PROCESSING_DIR:?}/${safe_name}"_*

	# Create temporary directory with error handling
	temp_dir=$(mktemp -d "$PROCESSING_DIR/${safe_name}_XXXX")
	local mktemp_exit=$?

	if [[ $mktemp_exit -ne 0 ]]; then
		log_error "Failed to create temporary directory"
		return 1
	fi

	log_info "STAGING TO PROCESSING DIR: $temp_dir"
	print_line

	# Copy files with progress and error handling
	rsync -a "$text_directory/" "$temp_dir/"

	# Verify copy integrity
	rsync_output=$(rsync -a --checksum --dry-run "$text_directory/" "$temp_dir/")
	rsync_exit=$?

	if [[ $rsync_exit -eq 0 ]]; then
		if [[ -z $rsync_output ]]; then
			log_success "STAGING COMPLETE"
		else
			log_warn "Files may differ:"
			log_warn "$rsync_output"
		fi
	else
		log_error "Failed to verify staging integrity"
		rm -rf "$temp_dir"
		return 1
	fi

	# Look for text files with various extensions
	mapfile -t text_array < <(find "$temp_dir" -type f -name "*.txt" | sort -h)

	if [[ ${#text_array[@]} -eq 0 ]]; then
		log_error "No TEXT files found in $temp_dir"
		log_info "DEBUG: Directory structure (first 5 files):"
		find "$temp_dir" -type f | head -5 | while read -r file; do
			log_info "$file"
		done
		print_line
		rm -rf "$temp_dir"
		return 1
	else
		log_success "Found ${#text_array[@]} text files. Continue Processing ..."
		print_line
		# Copy array to the reference
		RESULT_ARRAY=("${text_array[@]}")
	fi
}

are_png_and_text()
{
	local -a pdf_array=("$@")
	local pdf_name=""
	local png_path=""
	local text_path=""
	local png_count=0
	local text_count=0

	TEXT_DIRS_GLOBAL=()

	for pdf_name in "${pdf_array[@]}"; do
		log_info "Checking document: $pdf_name"
		png_path="$OUTPUT_DIR/$pdf_name/png"
		text_path="$OUTPUT_DIR/$pdf_name/text"

		if [[ -d $png_path ]] && [[ -d $text_path ]]; then
			png_count=$(find "$png_path" -type f | wc -l)
			text_count=$(find "$text_path" -type f | wc -l)
			if [[ $text_count -gt 0 ]] && [[ $text_count -eq $png_count ]]; then
				log_info "PNG: $png_count | TEXT: $text_count"
				log_info "adding directory for processing"
				print_line
				TEXT_DIRS_GLOBAL+=("$text_path")
			else
				log_info "TEXT and PNG do not match"
				log_warn "Review $text_path"
				print_line
			fi
		else
			log_warn "Confirm paths $png_path and $text_path"
			print_line
		fi
	done

	if [[ ${#TEXT_DIRS_GLOBAL[@]} -eq 0 ]]; then
		log_error "No directories to process with valid png and text"
		print_line
		exit 1
	else
		log_success "Found directories to process"
		return 0
	fi
}

get_last_two_dirs()
{
	local full_path="$1"
	local parent_dir=""
	local current_dir=""

	parent_dir=$(basename "$(dirname "$full_path")")
	current_dir=$(basename "$full_path")
	echo "$parent_dir/$current_dir"
}

main()
{
	local pdf_array=()
	local text_path=""
	local staging_dir_name=""
	local storage_dir=""
	local pre_process_exit=0

	# Load configuration
	INPUT_DIR=$(get_config "paths.input_dir")
	OUTPUT_DIR=$(get_config "paths.output_dir")
	PROCESSING_DIR=$(get_config "processing_dir.polish_text")
	CEREBRAS_API_KEY_VAR=$(get_config "cerebras_api.api_key_variable")
	POLISH_MODEL=$(get_config "cerebras_api.polish_model")
	MAX_TOKENS=$(get_config "cerebras_api.max_tokens")
	TEMPERATURE=$(get_config "cerebras_api.temperature")
	TOP_P=$(get_config "cerebras_api.top_p")
	LOG_DIR=$(get_config "logs_dir.polish_text")
	MAX_API_RETRIES=$(get_config "retry.max_retries" "5")
	RETRY_DELAY_SECONDS=$(get_config "retry.retry_delay_seconds" "30")
	FAILED_LOG="$LOG_DIR/failed_pages.log"

	# Reset directories

	mkdir -p "$LOG_DIR" "$PROCESSING_DIR"
	rm -rf "$PROCESSING_DIR" "$LOG_DIR"
	mkdir -p "$LOG_DIR" "$PROCESSING_DIR"
	LOG_FILE="$LOG_DIR/log_$(date +'%Y%m%d_%H%M%S').log"
	touch "$LOG_FILE" "$FAILED_LOG"

	log_info "RESETTING DIRS"
	log_info "Script started. Log file: $LOG_FILE"

	check_dependencies

	# Get all pdf files in INPUT_DIR (directory for pdf raw files)
	mapfile -t pdf_array < <(find "$INPUT_DIR" -type f -name "*.pdf" -exec basename {} .pdf \;)

	if [[ ${#pdf_array[@]} -eq 0 ]]; then
		log_error "No pdf files in input directory"
		exit 1
	else
		log_success "Found pdf for processing."
	fi
	print_line

	# Confirm we have text to process
	# Text should have the same number of files as png
	are_png_and_text "${pdf_array[@]}"
	local are_png_exit=$?

	if [[ $are_png_exit -eq 0 ]]; then
		for text_path in "${TEXT_DIRS_GLOBAL[@]}"; do
			log_info "PROCESSING: $text_path"
			staging_dir_name=$(get_last_two_dirs "$text_path")
			storage_dir="${OUTPUT_DIR}/$(basename "$(dirname "$text_path")")/polished"
			mkdir -p "$storage_dir"

			pre_process_text "$text_path" "$staging_dir_name" "$storage_dir"
			pre_process_exit=$?

			if [[ $pre_process_exit -eq 0 ]]; then
				log_info "Captured ${#RESULT_ARRAY[@]} files:"
				print_line
				polish_text "$storage_dir"
			fi
		done
	fi

	log_success "All processing completed successfully"
	return 0
}

main "$@"
