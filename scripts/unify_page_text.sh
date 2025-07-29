#!/usr/bin/env bash
# Combines sequential pages (1+2+3, 4+5+6, etc.) into unified_text text files
# Validates text directory by comparing with PNG directory
# Processes incomplete directories with proper retry logic

set -euo pipefail

# --- Global Constants ---
declare -r CURL_TIMEOUT_GLOBAL=120
declare -r RATE_LIMIT_SLEEP_GLOBAL=60

# --- Global Variables ---
declare LOG_FILE_GLOBAL=""
declare FAILED_LOG_GLOBAL=""
declare -a TEXT_DIRS_GLOBAL=()
declare -a RESULT_ARRAY_GLOBAL=()

# --- Configuration Variables (loaded in main) ---
declare INPUT_DIR_GLOBAL=""
declare OUTPUT_DIR_GLOBAL=""
declare PROCESSING_DIR_GLOBAL=""
declare CEREBRAS_API_KEY_VAR_GLOBAL=""
declare POLISH_MODEL_GLOBAL=""
declare MAX_TOKENS_GLOBAL=""
declare TEMPERATURE_GLOBAL=""
declare TOP_P_GLOBAL=""
declare LOG_DIR_GLOBAL=""
declare MAX_API_RETRIES_GLOBAL=""
declare RETRY_DELAY_SECONDS_GLOBAL=""
declare SYSTEM_PROMPT_GLOBAL=""
declare USER_PROMPT_TEMPLATE_GLOBAL=""

# --- Dependencies Check ---
check_dependencies()
{
	local -a deps=("yq" "jq" "curl" "rsync" "mktemp")
	local dep=""
	local cmd_output=""

	for dep in "${deps[@]}"; do
		cmd_output=$(command -v "$dep" 2>&1)
		if [[ -z $cmd_output ]]; then
			log_error "Dependency '$dep' is not installed."
			return 1
		fi
	done

	if [[ -z ${CEREBRAS_API_KEY_VAR_GLOBAL} ]]; then
		log_error "CEREBRAS_API_KEY_VAR_GLOBAL not configured"
		return 1
	fi

	if [[ -z ${!CEREBRAS_API_KEY_VAR_GLOBAL:-} ]]; then
		log_error "API key variable '$CEREBRAS_API_KEY_VAR_GLOBAL' not set"
		return 1
	fi

	if [[ -z ${POLISH_MODEL_GLOBAL} ]]; then
		log_error "POLISH_MODEL_GLOBAL not set"
		return 1
	fi

	if [[ -z ${SYSTEM_PROMPT_GLOBAL} ]]; then
		log_error "SYSTEM_PROMPT_GLOBAL not loaded from config"
		return 1
	fi

	if [[ -z ${USER_PROMPT_TEMPLATE_GLOBAL} ]]; then
		log_error "USER_PROMPT_TEMPLATE_GLOBAL not loaded from config"
		return 1
	fi

	log_success "Dependencies verified"
	return 0
}

# --- Call Cerebras API ---
call_api_cerebras()
{
	local payload_file="$1"
	local response_file=""
	local curl_error_file=""
	local http_code=""
	local curl_output=""
	local content=""
	local full_response=""
	local curl_exit=""

	response_file=$(mktemp -p "$PROCESSING_DIR_GLOBAL" "api_response.XXXXXX")
	curl_error_file=$(mktemp -p "$PROCESSING_DIR_GLOBAL" "curl_error.XXXXXX")

	curl_output=$(curl --fail --silent --show-error -w "%{http_code}" -o "$response_file" \
		--request POST \
		--url "https://api.cerebras.ai/v1/chat/completions" \
		-H "Content-Type: application/json" \
		-H "Authorization: Bearer ${!CEREBRAS_API_KEY_VAR_GLOBAL}" \
		-d @"$payload_file" \
		--max-time "$CURL_TIMEOUT_GLOBAL" 2>"$curl_error_file")
	curl_exit="$?"

	http_code="$curl_output"

	if [[ $http_code -eq 429 ]]; then
		log_warn "Rate limit hit (429), sleeping for $RATE_LIMIT_SLEEP_GLOBAL seconds"
		sleep "$RATE_LIMIT_SLEEP_GLOBAL"
		rm -f "$response_file" "$curl_error_file"
		return 1
	fi

	if [[ $curl_exit -ne 0 ]] || [[ $http_code -ne 200 ]] || [[ ! -s $response_file ]]; then
		log_error "Cerebras API call failed with HTTP code: $http_code"
		if [[ -f $curl_error_file ]]; then
			local curl_error_content=""
			curl_error_content=$(<"$curl_error_file")
			log_error "Curl error: $curl_error_content"
		fi
		if [[ -f $response_file ]]; then
			local response_content=""
			response_content=$(<"$response_file")
			log_error "Response content: $response_content"
		fi
		rm -f "$response_file" "$curl_error_file"
		return 1
	fi

	rm -f "$curl_error_file"

	full_response=$(<"$response_file")

	# Check if response is streaming format or regular format
	local jq_check_output=""
	jq_check_output=$(echo "$full_response" | head -1 | jq -e '.choices[0].delta' 2>&1)
	if [[ $jq_check_output ]]; then
		content=""
		while IFS= read -r line; do
			if [[ -z $line ]]; then
				continue
			fi
			local delta_content=""
			local jq_delta_output=""
			jq_delta_output=$(echo "$line" | jq -r '.choices[0].delta.content // empty' 2>&1)
			local jq_delta_exit="$?"
			if [[ $jq_delta_exit -eq 0 ]]; then
				delta_content="$jq_delta_output"
			else
				delta_content=""
			fi
			if [[ -n $delta_content ]] && [[ $delta_content != "null" ]]; then
				content+="$delta_content"
			fi
		done <<<"$full_response"
	else
		content=$(echo "$full_response" | jq -r '.choices[0].message.content // empty')
	fi

	if [[ -z $content ]] || [[ $content == "null" ]]; then
		log_error "Failed to extract content from Cerebras API response"
		log_error "Full API response: $full_response"
		rm -f "$response_file"
		return 1
	fi

	# Remove tool call content if present
	content=$(echo "$content" | sed '/<tool_call>/,/<\/think>/d')

	printf '%s' "$content" >"$response_file"
	printf '%s' "$response_file"
}

# --- Get next unified_text index ---
get_next_start_index()
{
	local storage_dir="$1"
	local max_index=-1
	local unified_text_file=""
	local index=""

	if [[ ! -d $storage_dir ]]; then
		printf '%s' "0"
		return 0
	fi

	while IFS= read -r -d '' unified_text_file; do
		if [[ $unified_text_file =~ unified_text_([0-9]+)\.txt$ ]]; then
			index="${BASH_REMATCH[1]}"
			if [[ $index -gt $max_index ]]; then
				max_index="$index"
			fi
		fi
	done < <(find "$storage_dir" -name "unified_text_*.txt" -print0)

	if [[ $max_index -eq -1 ]]; then
		printf '%s' "0"
	else
		printf '%s' $((max_index + 1))
	fi
}

# --- Process a group of 3 text files ---
process_text_group()
{
	local first_file="$1"
	local second_file="$2"
	local third_file="$3"
	local output_index="$4"
	local storage_dir="$5"

	local desc=""
	local unified_text_file=""
	local combined_text=""
	local user_prompt=""
	local payload_file=""
	local retry_count=0
	local api_response_file=""
	local unified_text_text=""
	local output_file_path=""
	local call_exit=""
	local store_result=""
	local store_exit=""

	unified_text_file="unified_text_${output_index}.txt"
	desc="$(basename "$first_file")"

	if [[ -n $second_file ]]; then
		desc="$desc + $(basename "$second_file")"
	fi
	if [[ -n $third_file ]]; then
		desc="$desc + $(basename "$third_file")"
	fi

	log_info "Processing: $desc -> $unified_text_file"

	combined_text=$(<"$first_file")
	if [[ -n $second_file ]] && [[ -r $second_file ]]; then
		combined_text+=$'\n'
		combined_text+=$(<"$second_file")
	fi
	if [[ -n $third_file ]] && [[ -r $third_file ]]; then
		combined_text+=$'\n'
		combined_text+=$(<"$third_file")
	fi

	user_prompt=$(printf '%s' "$USER_PROMPT_TEMPLATE_GLOBAL" "$combined_text /no_think")

	payload_file=$(mktemp -p "$PROCESSING_DIR_GLOBAL" "api_payload.XXXXXX")

	jq -n \
		--arg model "$POLISH_MODEL_GLOBAL" \
		--argjson max_tokens "$MAX_TOKENS_GLOBAL" \
		--argjson temperature "$TEMPERATURE_GLOBAL" \
		--argjson top_p "$TOP_P_GLOBAL" \
		--arg system_content "$SYSTEM_PROMPT_GLOBAL" \
		--arg user_content "$user_prompt" \
		'{
          "model": $model,
          "stream": false,
          "max_tokens": $max_tokens,
          "temperature": $temperature,
          "top_p": $top_p,
          "messages": [
            { "role": "system", "content": $system_content },
            { "role": "user", "content": $user_content }
          ]
        }' >"$payload_file"

	while [[ $retry_count -lt $MAX_API_RETRIES_GLOBAL ]]; do
		api_response_file=$(call_api_cerebras "$payload_file")
		call_exit="$?"

		if [[ $call_exit -eq 0 ]]; then
			sleep 10
			break
		fi

		retry_count=$((retry_count + 1))
		if [[ $retry_count -lt $MAX_API_RETRIES_GLOBAL ]]; then
			log_warn "API retry $retry_count/$MAX_API_RETRIES_GLOBAL for $unified_text_file"
			sleep "$RETRY_DELAY_SECONDS_GLOBAL"
		fi
	done

	rm -f "$payload_file"

	if [[ -z $api_response_file ]]; then
		log_error "API call failed after $MAX_API_RETRIES_GLOBAL retries for $unified_text_file"
		return 1
	fi

	unified_text_text=$(<"$api_response_file")
	rm -f "$api_response_file"

	if [[ -z $unified_text_text ]]; then
		log_error "Empty unified_text text received for $unified_text_file"
		return 1
	fi

	output_file_path="$storage_dir/$unified_text_file"
	store_result=$(printf '%s' "$unified_text_text" >"$output_file_path" 2>&1)
	store_exit="$?"

	if [[ $store_exit -eq 0 ]]; then
		log_success "Saved $output_file_path"
		return 0
	else
		log_error "Failed to save unified_text text to $output_file_path"
		if [[ -n $store_result ]]; then
			log_error "Store error: $store_result"
		fi
		return 1
	fi
}

# --- Polish all text files ---
polish_text()
{
	local storage_dir="$1"
	local total_files=${#RESULT_ARRAY_GLOBAL[@]}
	local start_index=""
	local output_index=""
	local iteration_count=0
	local first_file=""
	local second_file=""
	local third_file=""
	local end_file=""
	local group_result=""

	if [[ $total_files -eq 0 ]]; then
		log_error "No text files to process"
		return 1
	fi

	start_index=$(get_next_start_index "$storage_dir")
	output_index="$start_index"

	if [[ $start_index -gt 0 ]]; then
		log_info "Resuming from unified_text index $start_index"
	fi

	log_info "Processing $total_files text files in groups of 3"
	print_line

	iteration_count=$((start_index * 3))

	while [[ $iteration_count -lt $total_files ]]; do
		first_file="${RESULT_ARRAY_GLOBAL[iteration_count]}"
		second_file=""
		third_file=""

		if [[ ! -r $first_file ]]; then
			log_error "Cannot read file: $first_file"
			return 1
		fi

		if [[ $((iteration_count + 1)) -lt $total_files ]]; then
			local candidate="${RESULT_ARRAY_GLOBAL[$((iteration_count + 1))]}"
			if [[ -r $candidate ]]; then
				second_file="$candidate"
			fi
		fi

		if [[ $((iteration_count + 2)) -lt $total_files ]]; then
			local candidate="${RESULT_ARRAY_GLOBAL[$((iteration_count + 2))]}"
			if [[ -r $candidate ]]; then
				third_file="$candidate"
			fi
		fi

		end_file=$((iteration_count + 3))
		if [[ $end_file -gt $total_files ]]; then
			end_file="$total_files"
		fi

		log_info "Processing group $output_index: files $((iteration_count + 1))-$end_file of $total_files"
		print_line

		process_text_group "$first_file" "$second_file" "$third_file" "$output_index" "$storage_dir"
		group_result="$?"

		if [[ $group_result -eq 0 ]]; then
			log_success "Processed unified_text_$output_index"
		else
			log_warn "Failed to process group $output_index"
		fi

		output_index=$((output_index + 1))
		iteration_count=$((iteration_count + 3))
	done

	print_line
	return 0
}

# --- Prepare text files ---
pre_process_text()
{
	local text_directory="$1"
	local processing_text_dir="$2"
	local storage_dir="$3"
	local safe_name=""
	local temp_dir=""
	local rsync_output=""
	local rsync_exit=""
	local -a text_array=()
	local file=""
	local mktemp_exit=""

	RESULT_ARRAY_GLOBAL=()

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

	if [[ -z $PROCESSING_DIR_GLOBAL ]]; then
		log_error "PROCESSING_DIR_GLOBAL not set"
		return 1
	fi

	log_info "STORAGE: $storage_dir"
	print_line

	safe_name=$(echo "$processing_text_dir" | tr '/' '_')
	log_info "Removing old staging directories: ${PROCESSING_DIR_GLOBAL}/${safe_name}_*"
	rm -rf "${PROCESSING_DIR_GLOBAL:?}/${safe_name}"_*

	temp_dir=$(mktemp -d "$PROCESSING_DIR_GLOBAL/${safe_name}_XXXX")
	mktemp_exit="$?"
	if [[ $mktemp_exit -ne 0 ]]; then
		log_error "Failed to create temporary directory"
		return 1
	fi

	log_info "STAGING TO PROCESSING DIR: $temp_dir"
	print_line

	rsync_output=$(rsync -a "$text_directory/" "$temp_dir/" 2>&1)
	rsync_exit="$?"

	if [[ $rsync_exit -ne 0 ]]; then
		log_error "Failed to stage files: $rsync_output"
		rm -rf "$temp_dir"
		return 1
	fi

	rsync_output=$(rsync -a --checksum --dry-run "$text_directory/" "$temp_dir/" 2>&1)
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
		RESULT_ARRAY_GLOBAL=("${text_array[@]}")
	fi

	return 0
}

# --- Validate PNG and TEXT alignment ---
are_png_and_text()
{
	local -a pdf_array=("$@")
	local pdf_name=""
	local png_path=""
	local text_path=""
	local png_count=""
	local text_count=""

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
				log_info "Adding directory for processing: $text_path"
				print_line
				TEXT_DIRS_GLOBAL+=("$text_path")
			else
				log_info "TEXT and PNG do not match: $text_path"
				log_warn "Review $text_path"
				print_line
			fi
		else
			log_warn "Missing paths: PNG=$png_path, TEXT=$text_path"
			print_line
		fi
	done

	if [[ ${#TEXT_DIRS_GLOBAL[@]} -eq 0 ]]; then
		log_error "No directories to process with valid PNG and TEXT"
		print_line
		return 1
	else
		log_success "Found ${#TEXT_DIRS_GLOBAL[@]} directories to process"
		return 0
	fi
}

# --- Extract last two directory components ---
get_last_two_dirs()
{
	local full_path="$1"
	local parent_dir=""
	local current_dir=""

	parent_dir=$(basename "$(dirname "$full_path")")
	current_dir=$(basename "$full_path")
	printf '%s' "$parent_dir/$current_dir"
}

# --- Load configuration from project.toml ---
load_config()
{
	local config_file="project.toml"
	local config_helper="helpers/get_config_helper.sh"
	local helper_exit=""

	if [[ ! -f $config_file ]]; then
		log_error "Configuration file not found: $config_file"
		return 1
	fi

	if [[ ! -f $config_helper ]]; then
		log_error "Configuration helper not found: $config_helper"
		return 1
	fi

	# Load configuration variables
	INPUT_DIR_GLOBAL=$($config_helper "paths.input_dir" 2>&1)
	helper_exit="$?"
	if [[ $helper_exit -ne 0 ]]; then
		log_error "Failed to load paths.input_dir: $INPUT_DIR_GLOBAL"
		return 1
	fi

	OUTPUT_DIR_GLOBAL=$($config_helper "paths.output_dir" 2>&1)
	helper_exit="$?"
	if [[ $helper_exit -ne 0 ]]; then
		log_error "Failed to load paths.output_dir: $OUTPUT_DIR_GLOBAL"
		return 1
	fi

	PROCESSING_DIR_GLOBAL=$($config_helper "processing_dir.polish_text" 2>&1)
	helper_exit="$?"
	if [[ $helper_exit -ne 0 ]]; then
		log_error "Failed to load processing_dir.polish_text: $PROCESSING_DIR_GLOBAL"
		return 1
	fi

	CEREBRAS_API_KEY_VAR_GLOBAL=$($config_helper "cerebras_api.api_key_variable" 2>&1)
	helper_exit="$?"
	if [[ $helper_exit -ne 0 ]]; then
		log_error "Failed to load cerebras_api.api_key_variable: $CEREBRAS_API_KEY_VAR_GLOBAL"
		return 1
	fi

	POLISH_MODEL_GLOBAL=$($config_helper "cerebras_api.polish_model" 2>&1)
	helper_exit="$?"
	if [[ $helper_exit -ne 0 ]]; then
		log_error "Failed to load cerebras_api.polish_model: $POLISH_MODEL_GLOBAL"
		return 1
	fi

	MAX_TOKENS_GLOBAL=$($config_helper "cerebras_api.max_tokens" 2>&1)
	helper_exit="$?"
	if [[ $helper_exit -ne 0 ]]; then
		log_error "Failed to load cerebras_api.max_tokens: $MAX_TOKENS_GLOBAL"
		return 1
	fi

	TEMPERATURE_GLOBAL=$($config_helper "cerebras_api.temperature" 2>&1)
	helper_exit="$?"
	if [[ $helper_exit -ne 0 ]]; then
		log_error "Failed to load cerebras_api.temperature: $TEMPERATURE_GLOBAL"
		return 1
	fi

	TOP_P_GLOBAL=$($config_helper "cerebras_api.top_p" 2>&1)
	helper_exit="$?"
	if [[ $helper_exit -ne 0 ]]; then
		log_error "Failed to load cerebras_api.top_p: $TOP_P_GLOBAL"
		return 1
	fi

	LOG_DIR_GLOBAL=$($config_helper "logs_dir.polish_text" 2>&1)
	helper_exit="$?"
	if [[ $helper_exit -ne 0 ]]; then
		log_error "Failed to load logs_dir.polish_text: $LOG_DIR_GLOBAL"
		return 1
	fi

	MAX_API_RETRIES_GLOBAL=$($config_helper "retry.max_retries" 2>&1)
	helper_exit="$?"
	if [[ $helper_exit -ne 0 ]]; then
		log_error "Failed to load retry.max_retries: $MAX_API_RETRIES_GLOBAL"
		return 1
	fi

	RETRY_DELAY_SECONDS_GLOBAL=$($config_helper "retry.retry_delay_seconds" 2>&1)
	helper_exit="$?"
	if [[ $helper_exit -ne 0 ]]; then
		log_error "Failed to load retry.retry_delay_seconds: $RETRY_DELAY_SECONDS_GLOBAL"
		return 1
	fi

	SYSTEM_PROMPT_GLOBAL=$($config_helper "prompts.polish_text.system" 2>&1)
	helper_exit="$?"
	if [[ $helper_exit -ne 0 ]]; then
		log_error "Failed to load prompts.polish_text.system: $SYSTEM_PROMPT_GLOBAL"
		return 1
	fi

	USER_PROMPT_TEMPLATE_GLOBAL=$($config_helper "prompts.polish_text.user" 2>&1)
	helper_exit="$?"
	if [[ $helper_exit -ne 0 ]]; then
		log_error "Failed to load prompts.polish_text.user: $USER_PROMPT_TEMPLATE_GLOBAL"
		return 1
	fi

	log_success "Configuration loaded successfully"
	return 0
}

# --- Main ---
main()
{
	local -a pdf_array=()
	local text_path=""
	local staging_dir_name=""
	local storage_dir=""
	local pre_process_exit=""
	local logger="helpers/logging_utils_helper.sh"
	local check_deps_exit=""
	local png_text_exit=""
	local config_exit=""

	# Load configuration first
	load_config
	config_exit="$?"
	if [[ $config_exit -ne 0 ]]; then
		echo "FATAL: Configuration loading failed" >&2
		exit 1
	fi

	# Set log files with GLOBAL suffix for clarity
	LOG_FILE_GLOBAL="$LOG_DIR_GLOBAL/log_$(date +'%Y%m%d_%H%M%S').log"
	FAILED_LOG_GLOBAL="$LOG_DIR_GLOBAL/failed_pages.log"

	# Setup directories
	mkdir -p "$LOG_DIR_GLOBAL" "$PROCESSING_DIR_GLOBAL"
	rm -rf "${PROCESSING_DIR_GLOBAL:?}"/*
	mkdir -p "$PROCESSING_DIR_GLOBAL"
	touch "$LOG_FILE_GLOBAL" "$FAILED_LOG_GLOBAL"

	# Source logging utilities - must happen after LOG_FILE_GLOBAL is set
	if [[ ! -f $logger ]]; then
		echo "FATAL: Logging helper not found: $logger" >&2
		exit 1
	fi

	# Export LOG_FILE for the logging helper (maintains compatibility)
	export LOG_FILE="$LOG_FILE_GLOBAL"
	source "$logger"

	log_info "RESETTING DIRS"
	log_info "Script started. Log file: $LOG_FILE_GLOBAL"

	# Check dependencies
	check_dependencies
	check_deps_exit="$?"
	if [[ $check_deps_exit -ne 0 ]]; then
		log_error "Dependency check failed"
		exit 1
	fi

	# Find PDF files in input directory
	mapfile -t pdf_array < <(find "$INPUT_DIR_GLOBAL" -type f -name "*.pdf" -exec basename {} .pdf \;)

	if [[ ${#pdf_array[@]} -eq 0 ]]; then
		log_error "No PDF files in input directory: $INPUT_DIR_GLOBAL"
		exit 1
	else
		log_success "Found ${#pdf_array[@]} PDFs for processing."
	fi
	print_line

	# Validate PNG/TEXT directories
	are_png_and_text "${pdf_array[@]}"
	png_text_exit="$?"
	if [[ $png_text_exit -ne 0 ]]; then
		log_error "No valid directories to process"
		exit 1
	fi

	# Process each text directory
	for text_path in "${TEXT_DIRS_GLOBAL[@]}"; do
		log_info "PROCESSING: $text_path"
		staging_dir_name=$(get_last_two_dirs "$text_path")
		storage_dir="$(dirname "$(dirname "$text_path")")/unified_text"
		mkdir -p "$storage_dir"

		pre_process_text "$text_path" "$staging_dir_name" "$storage_dir"
		pre_process_exit="$?"

		if [[ $pre_process_exit -eq 0 ]]; then
			log_info "Captured ${#RESULT_ARRAY_GLOBAL[@]} files:"
			print_line
			polish_text "$storage_dir"
		else
			log_error "Pre-processing failed for $text_path"
		fi
	done

	log_success "All processing completed successfully"
	return 0
}

# Execute main function
main "$@"
