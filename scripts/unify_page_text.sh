#!/usr/bin/env bash
# Combines sequential pages (1+2+3, 4+5+6, etc.) into unified text files
# Validates text directory by comparing with PNG directory
# Processes incomplete directories with proper retry logic

set -u

# --- Configuration ---
declare -r CURL_TIMEOUT_GLOBAL=120
declare -r RATE_LIMIT_SLEEP_GLOBAL=60

# --- Global Variables ---
declare CEREBRAS_API_KEY_VAR_GLOBAL=""
declare FAILED_LOG_GLOBAL=""
declare INPUT_DIR_GLOBAL=""
declare LOG_DIR_GLOBAL=""
declare LOG_FILE_GLOBAL=""
declare MAX_API_RETRIES_GLOBAL=0
declare MAX_TOKENS_GLOBAL=0
declare OUTPUT_DIR_GLOBAL=""
declare PROCESSING_DIR_GLOBAL=""
declare RETRY_DELAY_SECONDS_GLOBAL=0
declare TEMPERATURE_GLOBAL=0.0
declare TEXT_DIRS_GLOBAL=""
declare TOP_P_GLOBAL=0.0
declare UNIFY_TEXT_MODEL_GLOBAL=""
declare UNIFY_TEXT_PROMPT_GLOBAL=""

declare -a RESULT_ARRAY_GLOBAL=()

check_dependencies()
{
	# All local variables declared at the top
	local cmd_output=""
	local dep=""
	local deps=("yq" "jq" "curl" "rsync" "mktemp")

	for dep in "${deps[@]}"; do
		cmd_output=$(command -v "$dep")
		if [[ -z $cmd_output ]]; then
			log_error "Dependency '$dep' is not installed."
			exit 1
		fi
	done

	if [[ -z ${CEREBRAS_API_KEY_VAR_GLOBAL:-} ]]; then
		log_error "CEREBRAS_API_KEY_VAR_GLOBAL not configured"
		exit 1
	fi

	if [[ -z ${!CEREBRAS_API_KEY_VAR_GLOBAL:-} ]]; then
		log_error "API key variable '$CEREBRAS_API_KEY_VAR_GLOBAL' not set"
		exit 1
	fi

	if [[ -z ${UNIFY_TEXT_MODEL_GLOBAL:-} ]]; then
		log_error "UNIFY_TEXT_MODEL_GLOBAL not set"
		exit 1
	fi

	log_success "Dependencies verified"
	return 0
}

call_api_cerebras()
{
	# All local variables declared at the top
	local content=""
	local curl_exit=""
	local curl_output=""
	local delta_content=""
	local full_response=""
	local http_code=""
	local jq_exit=""
	local line=""
	local payload_file="$1"
	local response_file=""

	response_file=$(mktemp -p "$PROCESSING_DIR_GLOBAL" "api_response.XXXXXX")

	curl_output=$(curl --fail --silent --show-error -w "%{http_code}" -o "$response_file" \
		--request POST \
		--url "https://api.cerebras.ai/v1/chat/completions" \
		-H "Content-Type: application/json" \
		-H "Authorization: Bearer ${!CEREBRAS_API_KEY_VAR_GLOBAL}" \
		-d @"$payload_file" \
		--max-time "$CURL_TIMEOUT_GLOBAL")
	curl_exit="$?"

	http_code="$curl_output"

	# Handle 429 rate limit specifically
	if [[ $http_code -eq 429 ]]; then
		log_warn "Rate limit hit (429), sleeping for $RATE_LIMIT_SLEEP_GLOBAL seconds"
		sleep "$RATE_LIMIT_SLEEP_GLOBAL"
		rm -f "$response_file"
		return 1
	fi

	if [[ $curl_exit -ne 0 ]] || [[ $http_code -ne 200 ]] || [[ ! -s $response_file ]]; then
		log_error "Cerebras API call failed with HTTP code: $http_code"
		if [[ -f $response_file ]]; then
			log_error "Response file content: $(cat "$response_file")"
		fi
		rm -f "$response_file"
		return 1
	fi

	# Read the complete response
	full_response=$(<"$response_file")

	# Check if this is a streaming response by looking for multiple lines with "data:" prefix
	if echo "$full_response" | grep -q "^data:"; then
		# Streaming response - process each data line
		content=""
		while IFS= read -r line; do
			if [[ $line =~ ^data:\ (.*)$ ]]; then
				local json_data="${BASH_REMATCH[1]}"
				if [[ $json_data != "[DONE]" ]]; then
					delta_content=$(echo "$json_data" | jq -r '.choices[0].delta.content // empty' 2>&1)
					jq_exit="$?"
					if [[ -n $delta_content ]] && [[ $delta_content != "null" ]] && [[ $jq_exit -eq 0 ]]; then
						content="$content$delta_content"
					fi
				fi
			fi
		done <<<"$full_response"
	else
		# Regular JSON response format
		content=$(echo "$full_response" | jq -r '.choices[0].message.content // empty')
		jq_exit="$?"
		if [[ $jq_exit -ne 0 ]]; then
			log_error "Failed to parse JSON response"
			log_error "Full API response: $full_response"
			rm -f "$response_file"
			return 1
		fi
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
	printf '%s' "$response_file"
}

get_next_start_index()
{
	# All local variables declared at the top
	local index=""
	local max_index=-1
	local storage_dir="$1"
	local unified_file=""

	if [[ ! -d $storage_dir ]]; then
		printf '%s' "0"
		return 0
	fi

	while IFS= read -r -d '' unified_file; do
		if [[ $unified_file =~ unified_([0-9]+)\.txt$ ]]; then
			index="${BASH_REMATCH[1]}"
			if [[ $index -gt $max_index ]]; then
				max_index="$index"
			fi
		fi
	done < <(find "$storage_dir" -name "unified_*.txt" -print0)

	if [[ $max_index -eq -1 ]]; then
		printf '%s' "0"
	else
		printf '%s' "$((max_index + 1))"
	fi
}

process_text_group()
{
	# All local variables declared at the top
	local api_response_file=""
	local call_exit=""
	local combined_text=""
	local desc=""
	local first_file="$1"
	local jq_exit=""
	local output_file_path=""
	local output_index="$4"
	local payload_file=""
	local retry_count=0
	local second_file="$2"
	local storage_dir="$5"
	local system_prompt=""
	local third_file="$3"
	local unified_file=""
	local user_prompt=""
	local write_exit=""

	# Build file description
	desc="$first_file"
	unified_file="unified_${output_index}.txt"

	if [[ -n $second_file ]] && [[ $second_file != "" ]]; then
		desc="$desc + $(basename "$second_file")"
	fi

	if [[ -n $third_file ]] && [[ $third_file != "" ]]; then
		desc="$desc + $(basename "$third_file")"
	fi

	log_info "Processing: $desc -> $unified_file"

	# Combine text files
	combined_text=$(<"$first_file")
	if [[ -n $second_file ]] && [[ $second_file != "" ]]; then
		combined_text="$combined_text\n$(<"$second_file")"
	fi
	if [[ -n $third_file ]] && [[ $third_file != "" ]]; then
		combined_text="$combined_text\n$(<"$third_file")"
	fi
	system_prompt="$UNIFY_TEXT_PROMPT_GLOBAL"
	user_prompt="TEXT: $combined_text"

	# Ensure the storage directory exists
	if [[ ! -d $storage_dir ]]; then
		local mkdir_result=""
		local mkdir_exit=""
		mkdir_result=$(mkdir -p "$storage_dir" 2>&1)
		mkdir_exit="$?"
		if [[ $mkdir_exit -ne 0 ]]; then
			log_error "Failed to create storage directory: $storage_dir - $mkdir_result"
			return 1
		fi
	fi

	payload_file=$(mktemp -p "$PROCESSING_DIR_GLOBAL" "api_payload.XXXXXX")
	if [[ ! -f $payload_file ]]; then
		log_error "Failed to create temporary payload file."
		return 1
	fi

	jq -n \
		--arg model "$UNIFY_TEXT_MODEL_GLOBAL" \
		--argjson max_tokens "$MAX_TOKENS_GLOBAL" \
		--argjson temperature "$TEMPERATURE_GLOBAL" \
		--argjson top_p "$TOP_P_GLOBAL" \
		--arg system_content "$system_prompt" \
		--arg user_content "${user_prompt} /no_think" \
		'{
          "model": $model,
          "stream": true,
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

	jq_exit="$?"
	if [[ $jq_exit -ne 0 ]]; then
		log_error "jq command failed to write API payload."
		rm -f "$payload_file"
		return 1
	fi

	# Retry logic for API calls
	retry_count=0
	api_response_file=""

	while [[ $retry_count -lt $MAX_API_RETRIES_GLOBAL ]]; do
		api_response_file=$(call_api_cerebras "$payload_file")
		call_exit="$?"
		if [[ $call_exit -eq 0 && -f $api_response_file ]]; then
			sleep 10
			break
		fi
		retry_count=$((retry_count + 1))
		if [[ $retry_count -lt $MAX_API_RETRIES_GLOBAL ]]; then
			log_warn "API retry $retry_count/$MAX_API_RETRIES_GLOBAL for $unified_file"
			sleep "$RETRY_DELAY_SECONDS_GLOBAL"
		fi
	done

	rm -f "$payload_file"

	if [[ -z $api_response_file || ! -f $api_response_file ]]; then
		log_error "API call failed after $MAX_API_RETRIES_GLOBAL retries for $unified_file"
		return 1
	fi

	# Save the unified text to the output file
	output_file_path="${storage_dir}/${unified_file}"
	cat "$api_response_file" >"$output_file_path"
	write_exit="$?"

	if [[ $write_exit -eq 0 && -s $output_file_path ]]; then
		log_success "Saved $output_file_path"
		rm -f "$api_response_file"
		return 0
	else
		log_error "Failed to save unified text to $output_file_path (exit code $write_exit)"
		rm -f "$api_response_file"
		return 1
	fi
}

unify_text()
{
	# All local variables declared at the top
	local candidate=""
	local end_file=0
	local first_file=""
	local group_result=""
	local i=0
	local output_index=0
	local second_file=""
	local start_index=0
	local storage_dir="$1"
	local third_file=""
	local total_files="${#RESULT_ARRAY_GLOBAL[@]}"

	if [[ $total_files -eq 0 ]]; then
		log_error "No text files to process"
		return 1
	fi

	start_index=$(get_next_start_index "$storage_dir")

	if [[ $start_index -gt 0 ]]; then
		log_info "Resuming from unified index $start_index"
	fi

	log_info "Processing $total_files text files in groups of 3"
	print_line

	# Calculate starting file position based on start_index
	i=$((start_index * 3))
	output_index="$start_index"

	# Process files in groups of 3 starting from calculated position
	for (( ; i < total_files; i += 3)); do
		first_file="${RESULT_ARRAY_GLOBAL[i]}"
		second_file=""
		third_file=""

		# Check if files exist and are readable
		if [[ ! -r $first_file ]]; then
			log_error "Cannot read file: $first_file"
			return 1
		fi

		# Check if second file exists
		if [[ $((i + 1)) -lt $total_files ]]; then
			candidate="${RESULT_ARRAY_GLOBAL[$((i + 1))]}"
			if [[ -r $candidate ]]; then
				second_file="$candidate"
			fi
		fi

		# Check if third file exists
		if [[ $((i + 2)) -lt $total_files ]]; then
			candidate="${RESULT_ARRAY_GLOBAL[$((i + 2))]}"
			if [[ -r $candidate ]]; then
				third_file="$candidate"
			fi
		fi

		if [[ $((i + 3)) -le $total_files ]]; then
			end_file=$((i + 3))
		else
			end_file="$total_files"
		fi

		log_info "Processing group $output_index: files $((i + 1))-$end_file of $total_files"
		print_line

		# Call existing process_text_group function
		process_text_group "$first_file" "$second_file" "$third_file" "$output_index" "$storage_dir"
		group_result="$?"

		if [[ $group_result -eq 0 ]]; then
			log_success "Processed unified_$output_index"
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
	# All local variables declared at the top
	local file=""
	local mktemp_exit=""
	local processing_text_dir="$2"
	local rsync_exit=0
	local rsync_output=""
	local safe_name=""
	local storage_dir="$3"
	local temp_dir=""
	local text_array=()
	local text_directory="$1"

	# Reset
	RESULT_ARRAY_GLOBAL=()

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

	# Check if PROCESSING_DIR_GLOBAL is defined
	if [[ -z $PROCESSING_DIR_GLOBAL ]]; then
		log_error "PROCESSING_DIR_GLOBAL environment variable not set"
		return 1
	fi

	log_info "STORAGE $storage_dir"
	print_line

	# Create safe directory name
	safe_name=$(echo "$processing_text_dir" | tr '/' '_')

	log_info "Removing old directories with the same base directory"
	rm -rf "${PROCESSING_DIR_GLOBAL:?}/${safe_name}"_*

	# Create temporary directory with error handling
	temp_dir=$(mktemp -d "$PROCESSING_DIR_GLOBAL/${safe_name}_XXXX")
	mktemp_exit="$?"

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
	rsync_exit="$?"

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
	mapfile -t text_array < <(find "$temp_dir" -type f -name "*.txt" | sort -V)

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
		RESULT_ARRAY_GLOBAL=("${text_array[@]}")
	fi
}

are_png_and_text()
{
	# All local variables declared at the top
	local pdf_name=""
	local png_count=0
	local png_path=""
	local text_count=0
	local text_path=""
	local -a pdf_array=("$@")

	TEXT_DIRS_GLOBAL=()

	for pdf_name in "${pdf_array[@]}"; do
		log_info "Checking document: $pdf_name"
		png_path="$OUTPUT_DIR_GLOBAL/$pdf_name/png"
		text_path="$OUTPUT_DIR_GLOBAL/$pdf_name/text"

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
	# All local variables declared at the top
	local current_dir=""
	local full_path="$1"
	local parent_dir=""

	parent_dir=$(basename "$(dirname "$full_path")")
	current_dir=$(basename "$full_path")
	printf '%s/%s' "$parent_dir" "$current_dir"
}

main()
{
	# All local variables declared at the top
	local are_png_exit=""
	local logger="helpers/logging_utils_helper.sh"
	local pdf_array=()
	local pre_process_exit=0
	local staging_dir_name=""
	local storage_dir=""
	local text_path=""
	local config_helper="helpers/get_config_helper.sh"

	# Load configuration
	INPUT_DIR_GLOBAL=$($config_helper "paths.input_dir")
	OUTPUT_DIR_GLOBAL=$($config_helper "paths.output_dir")
	PROCESSING_DIR_GLOBAL=$($config_helper "processing_dir.unify_text")
	CEREBRAS_API_KEY_VAR_GLOBAL=$($config_helper "cerebras_api.api_key_variable")
	UNIFY_TEXT_MODEL_GLOBAL=$($config_helper "cerebras_api.unify_model")
	MAX_TOKENS_GLOBAL=$($config_helper "cerebras_api.max_tokens")
	TEMPERATURE_GLOBAL=$($config_helper "cerebras_api.temperature")
	TOP_P_GLOBAL=$($config_helper "cerebras_api.top_p")
	LOG_DIR_GLOBAL=$($config_helper "logs_dir.unify_text")
	MAX_API_RETRIES_GLOBAL=$($config_helper "retry.max_retries")
	RETRY_DELAY_SECONDS_GLOBAL=$($config_helper "retry.retry_delay_seconds")
	UNIFY_TEXT_PROMPT_GLOBAL=$(config_helper "prompts.unify_text.prompt")
	FAILED_LOG_GLOBAL="$LOG_DIR_GLOBAL/failed_pages.log"

	# Reset directories
	mkdir -p "$LOG_DIR_GLOBAL" "$PROCESSING_DIR_GLOBAL"
	rm -rf "$PROCESSING_DIR_GLOBAL" "$LOG_DIR_GLOBAL"
	mkdir -p "$LOG_DIR_GLOBAL" "$PROCESSING_DIR_GLOBAL"
	LOG_FILE_GLOBAL="$LOG_DIR_GLOBAL/log_$(date +'%Y%m%d_%H%M%S').log"
	touch "$LOG_FILE_GLOBAL" "$FAILED_LOG_GLOBAL"

	source "$logger"

	log_info "RESETTING DIRS"
	log_info "Script started. Log file: $LOG_FILE_GLOBAL"

	check_dependencies

	# Get all pdf files in INPUT_DIR_GLOBAL (directory for pdf raw files)
	mapfile -t pdf_array < <(find "$INPUT_DIR_GLOBAL" -type f -name "*.pdf" -exec basename {} .pdf \;)

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
	are_png_exit="$?"

	if [[ $are_png_exit -eq 0 ]]; then
		for text_path in "${TEXT_DIRS_GLOBAL[@]}"; do
			log_info "PROCESSING: $text_path"
			staging_dir_name=$(get_last_two_dirs "$text_path")
			storage_dir="${OUTPUT_DIR_GLOBAL}/$(basename "$(dirname "$text_path")")/unified_text"
			mkdir -p "$storage_dir"

			pre_process_text "$text_path" "$staging_dir_name" "$storage_dir"
			pre_process_exit="$?"

			if [[ $pre_process_exit -eq 0 ]]; then
				log_info "Captured ${#RESULT_ARRAY_GLOBAL[@]} files:"
				print_line
				unify_text "$storage_dir"
			fi
		done
	fi

	log_success "All processing completed successfully"
	return 0
}

main "$@"
