#!/usr/bin/env bash
# Processes polished text files by combining pairs to create final TTS-ready versions
# Reads polished_X.txt files and creates final_Y.txt files

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
declare FINAL_MODEL=""
declare LOG_DIR=""
declare LOG_FILE=""
declare INPUT_DIR=""
declare POLISHED_DIRS_GLOBAL=""
declare FAILED_LOG=""
declare MAX_API_RETRIES=0
declare RETRY_DELAY_SECONDS=0
declare MAX_TOKENS=0
declare TEMPERATURE=0.0
declare TOP_P=0.0

declare -a POLISHED_FILES_ARRAY=()

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
		fi
		echo "Failed to read configuration key '$key' from $CONFIG_FILE"
	fi

	value="$yq_output"

	if [[ -z $value ]] && [[ -n $default_value ]]; then
		echo "$default_value"
	fi

	if [[ -z $value ]]; then
		echo "Missing required configuration key '$key' in $CONFIG_FILE"
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

	if [[ -z ${FINAL_MODEL:-} ]]; then
		log_error "FINAL_MODEL not set"
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
		done <"$response_file"
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

get_next_final_index()
{
	local storage_dir="$1"
	local max_index=-1
	local final_file=""
	local index=""

	if [[ ! -d $storage_dir ]]; then
		echo "1"
		return 0
	fi

	while IFS= read -r -d '' final_file; do
		if [[ $final_file =~ final_([0-9]+)\.txt$ ]]; then
			index="${BASH_REMATCH[1]}"
			if [[ $index -gt $max_index ]]; then
				max_index=$index
			fi
		fi
	done < <(find "$storage_dir" -name "final_*.txt" -print0)

	if [[ $max_index -eq -1 ]]; then
		echo "1"
	else
		echo $((max_index + 1))
	fi
}

process_polished_pair()
{
	local first_polished="$1"
	local second_polished="$2"
	local output_index="$3"
	local storage_dir="$4"

	local final_file=""
	local combined_text=""
	local system_prompt=""
	local user_prompt=""
	local payload_file=""
	local retry_count=0
	local api_response_file=""
	local final_text=""
	local output_file_path=""

	final_file="final_${output_index}.txt"

	log_info "Processing: $(basename "$first_polished") + $(basename "$second_polished") -> $final_file"

	# Combine polished files
	combined_text=$(<"$first_polished")
	combined_text="$combined_text\n$(<"$second_polished")"

	system_prompt="FOLLOW STRICTLY THIS GUIDE - You are an expert technical editor with a PhD in a STEM field, specializing in transforming scientific and technical text into seamless, educational content suitable for high-quality text-to-speech narration. Your audience includes listeners who cannot see the screen or text and cannot interpret symbols, formulas, code syntax, graphs, or diagrams.

Your primary responsibility is to remove redundancies and optimize material for spoken delivery, ensuring that every scientific or technical object is described explicitly and concretely in clear, continuous English. Whenever a scientific object is referenced—such as a specific variable, chemical, mathematical expression, programming construct, data structure, or laboratory instrument—always explain exactly what it is, what it represents, how it operates, and any essential characteristics needed for deep understanding. Never rely on symbols, shorthand, or mathematical notation. Instead of presenting code, formulas, or diagrams, describe in detail what they mean and how each part works. 

STRICTLY follow these rules for all input text:
- Render every abbreviation, acronym, technical notation, or symbol as explicit spoken English. For example, spell out technical acronyms: say ‘C P U’ for ‘CPU’, ‘R A M’ for ‘RAM’, ‘S Q L’ for ‘SQL’, etc.
- Express all scientific units and notations in full words: convert ‘MHz’ to ‘megahertz’, ‘kg’ to ‘kilogram’, ‘Hz’ to ‘hertz’, ‘GHz’ to ‘gigahertz’, and so on.
- Replace all programming operators, array notations, or code syntax with descriptive English. For example, ‘array’ becomes ‘array index two’, ‘i++’ becomes ‘increment i by one’, ‘x -= 2’ becomes ‘decrement x by two’.
- Verbalize all numerals, including those in hexadecimal and binary notation, as words, such as ‘zero x four F’ for ‘0x4F’, or ‘binary one zero zero one’.
- Substitute all special characters and mathematical operators with their spoken equivalents. Say ‘times’ for ‘*’, ‘slash’ for ‘/’, ‘backslash’ for ‘\’, ‘and’ for ‘&&’, ‘or’ for ‘||’, ‘is equal to’ for ‘==’, ‘is’ for ‘=’.
- Convert camelCase or snake_case identifiers into readable, full English phrases, such as ‘totalSum’ into ‘total sum’, ‘user_id’ into ‘user ID’.
- Never use any symbols, formatting artifacts, or shorthand—always express everything in a vivid, oral narrative style.
- Remove all code, formulas, or scientific notation—replace them with step-by-step logical explanations in clear English.
- Do not present explanations as lists or bullets. Write in a single, flowing, coherent narrative specifically tailored for spoken presentation.
- Avoid summarizing or repeating main points at the end; maintain a continuous explanatory style.
- Do not emphasize using typographical means; if necessary, use direct language (e.g., ‘it is very important to note’).
- Whenever ambiguous, choose the most concrete and unambiguous phrasing possible.

Examples:
- For ‘int a;’ say, ‘an integer array with ten elements’.
- For ‘1 + 1 = 2’, say, ‘one plus one equals two’.
- For ‘2HCl + 2Na → 2NaCl + H2’, describe the reaction as ‘two hydrogen chloride atoms plus two sodium atoms yields two sodium chloride molecules and one hydrogen molecule’.
- For ‘300MHz CPU’, say, ‘three hundred megahertz central processing unit’.
- For ‘result = x * y;’, say, ‘set the variable result to the value of x times y’.

Your output should be a continuous, clear, and richly detailed technical narrative as if painting a mental picture for a highly educated listener who cannot see the text, formulas, or diagrams. Never include visual artifacts or require referencing written information; all information must be self-contained and immediately comprehensible to a listener.
"

	user_prompt="Create TTS-ready educational content without using thinking, TEXT: $combined_text"

	payload_file=$(mktemp -p "$PROCESSING_DIR" "api_payload.XXXXXX")

	jq -n \
		--arg model "$FINAL_MODEL" \
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
			log_warn "API retry $retry_count/$MAX_API_RETRIES for $final_file"
			sleep "$RETRY_DELAY_SECONDS"
		fi
	done

	rm -f "$payload_file"

	if [[ -z $api_response_file ]]; then
		log_error "API call failed after $MAX_API_RETRIES retries for $final_file"
		return 1
	fi

	# Read the final content from the API response file
	final_text=$(<"$api_response_file")
	rm -f "$api_response_file"

	if [[ -z $final_text ]]; then
		log_error "Empty final text received for $final_file"
		return 1
	fi

	# Save the final text to the output file
	output_file_path="${storage_dir}/${final_file}"
	echo "$final_text" >"$output_file_path"
	local write_exit
	write_exit="$?"

	if [[ $write_exit -eq 0 ]]; then
		log_success "Saved $output_file_path"
		return 0
	else
		log_error "Failed to save final text to $output_file_path"
		return 1
	fi
}

create_final_text()
{
	local storage_dir="$1"
	local total_polished_files=${#POLISHED_FILES_ARRAY[@]}
	local start_index=1
	local output_index=1
	local i=1
	local first_polished=""
	local second_polished=""
	local pair_result=0

	if [[ $total_polished_files -eq 0 ]]; then
		log_error "No polished files to process"
		return 1
	fi

	start_index=$(get_next_final_index "$storage_dir")

	if [[ $start_index -gt 1 ]]; then
		log_info "Resuming from final index $start_index"
	fi

	log_info "Processing $total_polished_files polished files in pairs"
	print_line

	# Calculate starting file position based on start_index
	i=$(((start_index - 1) * 2))
	output_index=$start_index

	# Process files in pairs starting from calculated position
	for (( ; i < total_polished_files; i += 2)); do
		first_polished="${POLISHED_FILES_ARRAY[i]}"

		# Check if files exist and are readable
		if [[ ! -r $first_polished ]]; then
			log_error "Cannot read file: $first_polished"
			return 1
		fi

		# Check if second file exists for pairing
		if [[ $((i + 1)) -lt $total_polished_files ]]; then
			second_polished="${POLISHED_FILES_ARRAY[$((i + 1))]}"
			if [[ ! -r $second_polished ]]; then
				log_error "Cannot read file: $second_polished"
				return 1
			fi
		else
			# Handle odd number of files - process last file alone
			log_info "Processing single file: $(basename "$first_polished") -> final_${output_index}.txt"
			second_polished=""
		fi

		if [[ -n $second_polished ]]; then
			log_info "Processing pair $output_index: $(basename "$first_polished") + $(basename "$second_polished")"
		else
			log_info "Processing final single file $output_index: $(basename "$first_polished")"
		fi
		print_line

		# Call process_polished_pair function
		if [[ -n $second_polished ]]; then
			process_polished_pair "$first_polished" "$second_polished" "$output_index" "$storage_dir"
		else
			# For single file, just copy with minimal processing
			local single_file_content=""
			single_file_content=$(<"$first_polished")
			echo "$single_file_content" >"${storage_dir}/final_${output_index}.txt"
		fi
		pair_result=$?

		if [[ $pair_result -eq 0 ]]; then
			log_success "Processed final_$output_index"
		else
			log_warn "Failed to process final_$output_index"
		fi
		output_index=$((output_index + 1))
	done

	print_line
	return 0
}

collect_polished_files()
{
	local polished_directory="$1"
	local storage_dir="$2"
	local polished_array=()

	# Reset
	POLISHED_FILES_ARRAY=()

	# Input validation
	if [[ -z $polished_directory ]]; then
		log_error "Invalid polished directory: $polished_directory"
		return 1
	fi

	if [[ ! -d $polished_directory ]]; then
		log_error "Polished directory does not exist: $polished_directory"
		return 1
	fi

	if [[ -z $storage_dir ]] || [[ ! -d $storage_dir ]]; then
		log_error "Invalid storage directory: $storage_dir"
		return 1
	fi

	log_info "STORAGE $storage_dir"
	log_info "COLLECTING POLISHED FILES FROM: $polished_directory"
	print_line

	# Look for polished_*.txt files and sort them numerically
	mapfile -t polished_array < <(find "$polished_directory" -name "polished_*.txt" | sort -V)

	if [[ ${#polished_array[@]} -eq 0 ]]; then
		log_error "No polished_*.txt files found in $polished_directory"
		log_info "DEBUG: Directory contents:"
		find "$polished_directory" -type f | head -10 | while read -r file; do
			log_info "$file"
		done
		print_line
		return 1
	else
		log_success "Found ${#polished_array[@]} polished files to process"
		print_line
		# Copy array to the global reference
		POLISHED_FILES_ARRAY=("${polished_array[@]}")
		return 0
	fi
}

find_polished_directories()
{
	local -a pdf_array=("$@")
	local pdf_name=""
	local polished_path=""
	local polished_count=0

	POLISHED_DIRS_GLOBAL=()

	for pdf_name in "${pdf_array[@]}"; do
		log_info "Checking document: $pdf_name"
		polished_path="$OUTPUT_DIR/$pdf_name/polished"

		if [[ -d $polished_path ]]; then
			polished_count=$(find "$polished_path" -name "polished_*.txt" | wc -l)
			if [[ $polished_count -gt 0 ]]; then
				log_info "POLISHED FILES -> $polished_count"
				log_info "Adding directory for final processing"
				print_line
				POLISHED_DIRS_GLOBAL+=("$polished_path")
			else
				log_info "No polished_*.txt files found!"
				log_warn "Review $polished_path"
				print_line
			fi
		else
			log_warn "Polished directory not found: $polished_path"
			print_line
		fi
	done

	if [[ ${#POLISHED_DIRS_GLOBAL[@]} -eq 0 ]]; then
		log_error "No directories found with polished files to process"
		print_line
		exit 1
	else
		log_success "Found ${#POLISHED_DIRS_GLOBAL[@]} directories with polished files"
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
	local polished_path=""
	local storage_dir=""
	local collect_exit=0

	# Load configuration
	INPUT_DIR=$(get_config "paths.input_dir")
	OUTPUT_DIR=$(get_config "paths.output_dir")
	PROCESSING_DIR=$(get_config "processing_dir.final_text")
	CEREBRAS_API_KEY_VAR=$(get_config "cerebras_api.api_key_variable")
	FINAL_MODEL=$(get_config "cerebras_api.final_model")
	MAX_TOKENS=$(get_config "cerebras_api.max_tokens")
	TEMPERATURE=$(get_config "cerebras_api.temperature")
	TOP_P=$(get_config "cerebras_api.top_p")
	LOG_DIR=$(get_config "logs_dir.final_text")
	MAX_API_RETRIES=$(get_config "retry.max_retries" "5")
	RETRY_DELAY_SECONDS=$(get_config "retry.retry_delay_seconds" "30")
	FAILED_LOG="$LOG_DIR/failed_final.log"

	# Reset directories
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
		log_success "Found ${#pdf_array[@]} pdf files for processing"
	fi
	print_line

	# Find directories with polished files to process
	find_polished_directories "${pdf_array[@]}"
	local find_dirs_exit
	find_dirs_exit="$?"

	if [[ $find_dirs_exit -eq 0 ]]; then
		for polished_path in "${POLISHED_DIRS_GLOBAL[@]}"; do
			log_info "PROCESSING POLISHED FILES FROM: $polished_path"
			# Create final_text directory parallel to polished directory
			storage_dir="${OUTPUT_DIR}/$(basename "$(dirname "$polished_path")")/final_text"
			mkdir -p "$storage_dir"

			collect_polished_files "$polished_path" "$storage_dir"
			collect_exit=$?

			if [[ $collect_exit -eq 0 ]]; then
				log_info "Processing ${#POLISHED_FILES_ARRAY[@]} polished files into final versions"
				log_info "Saving final files to: $storage_dir"
				print_line
				create_final_text "$storage_dir"
			else
				log_warn "Skipping $polished_path due to collection failure"
			fi
		done
	fi

	log_success "All final text processing completed successfully"
	return 0
}

main "$@"
