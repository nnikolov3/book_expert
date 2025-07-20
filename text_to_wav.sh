#!/usr/bin/env bash
# ================================================================================================
# TEXT CHUNKS TO WAV CONVERTER (F5-TTS)
# Design: Niko Nikolov
# Code: Various LLMs
#===========
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
# - Flows should have robust retry mechanisms
# - Prefer mapfile or read -a to split command outputs (or quote to avoid splitting)
# - Do not expand the code. Do more with less.
# - Follow bash best practices.
# - No hard coding values.
# - See if you can use ${variable//search/replace} instead.
# COMMENTS SHOULD NOT BE REMOVED, INCONCISTENCIES SHOULD BE UPDATED WHEN DETECTED
# USE MARKDOWN WITHIN THE COMMENT BLOCKS FOR COMMENTS
# ===============================================================================================

set -euo pipefail

# --- Configuration ---
declare -r CONFIG_FILE="project.toml"

# --- Global Variables ---
declare OUTPUT_DIR=""
declare INPUT_DIR=""
declare F5_TTS_MODEL="E2TTS_Base"
declare -a CONCAT_DIRS_GLOBAL=()
declare CUR_PYTHON_PATH=""

# ================================================================================================
# UTILITY FUNCTIONS
# ================================================================================================

# ## get_config()
# Loads configuration from `project.toml`.
get_config()
{
	yq -r ".${1}" "$CONFIG_FILE"
}
# Add this near the top of your script
declare DEBUG=${DEBUG:-0}

debug_log()
{
	[[ $DEBUG -eq 1 ]] && echo "[DEBUG] $*" >&2
}
# ## log_info(), log_error()
# Log messages with timestamps.
log_info()
{
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $*"
}

log_error()
{
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

print_line()
{
	echo "======================================================================"
}

# Alternative simpler approach focusing on semantic boundaries
create_chunks()
{
	local text="$1"
	local -n chunks_ref="$2"
	local target_size="${3:-200}" # Target chunk size
	local current_chunk=""

	echo "INFO: Creating semantic chunks (target size: $target_size)"
	chunks_ref=()

	# Split on sentence boundaries and logical breaks
	local IFS=$'\n'
	local paragraphs=($(echo "$text" | sed 's/\. /.\n/g; s/\.\([A-Z]\)/.\n\1/g'))

	for paragraph in "${paragraphs[@]}"; do
		paragraph=$(echo "$paragraph" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
		[[ -z $paragraph ]] && continue

		if [[ -z $current_chunk ]]; then
			current_chunk="$paragraph"
		else
			local combined="$current_chunk $paragraph"
			if [[ ${#combined} -le $target_size ]]; then
				current_chunk="$combined"
			else
				# Current chunk is complete
				if [[ ${#current_chunk} -ge 30 ]]; then
					chunks_ref+=("$current_chunk")
				fi
				current_chunk="$paragraph"
			fi
		fi
	done

	# Add final chunk
	if [[ -n $current_chunk && ${#current_chunk} -ge 30 ]]; then
		chunks_ref+=("$current_chunk")
	elif [[ ${#chunks_ref[@]} -gt 0 && -n $current_chunk ]]; then
		chunks_ref[-1]+=" $current_chunk"
	fi

	echo "INFO: Created ${#chunks_ref[@]} semantic chunks"
	return 0
}

text_chunks_to_wav()
{
	local text="$1"
	local output_dir="$2"
	local -a text_chunks=()
	local chunk_num=1
	local total_chunks
	local preview_length=60
	local failed_chunks=0
	local temp_output

	echo "Starting the creation of text chunks"
	print_line

	# Validate inputs
	if [[ -z $text ]]; then
		echo "ERROR: NO TEXT!"
		print_line
		return 1
	else
		echo "SUCCESS: Text found. Chunk now."
		print_line
	fi

	if [[ -z $output_dir ]]; then
		echo "ERROR: No output directory specified"
		return 1
	fi

	# Call create_chunks with array reference
	if ! create_chunks "$text" text_chunks; then
		echo "ERROR: Failed to create text chunks"
		print_line
		return 1
	fi

	total_chunks=${#text_chunks[@]}

	# Check if we have any chunks
	if [[ $total_chunks -eq 0 ]]; then
		echo "ERROR: No text chunks were created - check input text"
		print_line
		return 1
	fi

	echo "INFO: Processing $total_chunks chunks"
	print_line

	for chunk in "${text_chunks[@]}"; do
		local chunk_filename
		local chunk_preview
		local chunk_length=${#chunk}
		local full_output_path

		# Skip empty chunks (safety check)
		if [[ -z $chunk ]]; then
			echo "Skipping empty chunk $chunk_num"
			chunk_num=$((chunk_num + 1))
			print_line
			continue
		fi

		printf -v chunk_filename "chunk_%04d.wav" "$chunk_num"
		full_output_path="$output_dir/$chunk_filename"

		# Dynamic preview length
		if [[ $chunk_length -gt $preview_length ]]; then
			chunk_preview="${chunk:0:preview_length}..."
		else
			chunk_preview="$chunk"
		fi

		# Progress indicator every 10 chunks
		if ((chunk_num % 10 == 0)); then
			log_info "Progress: $chunk_num/$total_chunks chunks completed" >&2
		fi

		# Show chunk info with character count
		log_info "[$chunk_num/$total_chunks] Processing ($chunk_length chars): $chunk_preview" >&2

		# Run F5-TTS with better error handling
		# Capture output to a variable for better error reporting
		if temp_output=$(f5-tts_infer-cli \
			-m "$F5_TTS_MODEL" \
			-t "$chunk" \
			-o "$output_dir" \
			-w "$chunk_filename" \
			--speed 0.9 \
			--remove_silence \
			--ref_text "" \
			--no_legacy_text 2>&1); then

			# Verify the output file was created and has reasonable size
			if [[ -f $full_output_path ]] && [[ -s $full_output_path ]]; then
				local file_size
				file_size=$(stat -c%s "$full_output_path" 2>/dev/null || echo 0)
				log_info "✅ Created $chunk_filename (${file_size} bytes)" >&2
			else
				log_error "❌ Output file not created or empty for chunk $chunk_num: $chunk_filename" >&2
				((failed_chunks++))
			fi
		else
			log_error "❌ Failed to process chunk $chunk_num: $chunk_preview" >&2
			if [[ -n $temp_output ]]; then
				log_error "F5-TTS error output: $temp_output" >&2
			fi
			((failed_chunks++))
		fi

		chunk_num=$((chunk_num + 1))
	done

	local successful_chunks=$((total_chunks - failed_chunks))

	if [[ $failed_chunks -gt 0 ]]; then
		log_error "⚠️  Completed with $failed_chunks failed chunks out of $total_chunks" >&2
	fi

	log_info "✅ Generated $successful_chunks audio chunks in $output_dir" >&2

	# List generated files for verification
	if [[ $successful_chunks -gt 0 ]]; then
		log_info "Generated files:" >&2
		find "$output_dir" -name "chunk_*.wav" -type f -printf "  %f (%s bytes)\n" 2>/dev/null | head -10 >&2
		if [[ $successful_chunks -gt 10 ]]; then
			log_info "  ... and $((successful_chunks - 10)) more files" >&2
		fi
	fi

	print_line
	return "$([[ $successful_chunks -gt 0 ]] && echo 0 || echo 1)"
}

activate_venv()
{
	local venv_path="$1"
	local activate_script="$venv_path/activate"

	if [[ ! -f $activate_script ]]; then
		echo "Error: Virtual environment not found at $venv_path"
		print_line
		return 1
	fi

	# shellcheck disable=SC1091
	source "$activate_script"
	echo "SUCCESS: Virtual environment activated"
	print_line

}

clean_text()
{
	local input="$1"
	local cleaned

	log_info "Cleaning text (input length: ${#input} chars)"

	# Check if input is empty
	if [[ -z $input ]]; then
		log_error "Empty input provided to clean_text"
		return 1
	fi

	cleaned=$(echo "$input" |
		sed 's/`//g' |
		sed 's/_/ /g' |
		sed 's/(/,/g' |
		sed 's/)//g' |
		sed 's/\bEFI /EFI /g' |
		sed 's/\bI\/O\b/input output/g' |
		sed 's/\bPCI\b/P C I/g' |
		sed 's/\bUSB\b/U S B/g' |
		sed 's/\bUEFI\b/U E F I/g' |
		sed 's/  */ /g' |
		sed 's/^[[:space:]]*//' |
		sed 's/[[:space:]]*$//')

	log_info "Text cleaned (output length: ${#cleaned} chars)"

	if [[ -z $cleaned ]]; then
		log_error "Text cleaning resulted in empty output"
		return 1
	fi

	echo "$cleaned"
}

is_concat()
{

	local -a pdf_array=("$@")
	CONCAT_DIRS_GLOBAL=()
	for pdf_name in "${pdf_array[@]}"; do
		echo "Checking document: $pdf_name"
		concat_path="${OUTPUT_DIR}/${pdf_name}/concat"
		if [[ -d $concat_path ]]; then
			concat_count=$(find "$concat_path" -type f | wc -l)
			if [[ $concat_count -eq 1 ]]; then
				echo "SUCCESS: Found $concat_count file to process"
				print_line
				CONCAT_DIRS_GLOBAL+=("$concat_path")
			else
				echo "WARN: Review $concat_path , no file found"
				print_line
			fi
		else
			echo "WARN: Confirm $concat_path"
			print_line
		fi
	done

	if [ ${#CONCAT_DIRS_GLOBAL[@]} -eq 0 ]; then
		echo "ERROR: No directories with concat text file."
		print_line
		exit 1
	else
		echo "SUCCESS: Found directories to process"
		print_line
		return 0
	fi
}

# ================================================================================================
# MAIN EXECUTION
# ================================================================================================
main()
{

	# Check configuration file
	if [[ ! -f $CONFIG_FILE ]]; then
		log_error "Config file not found: $CONFIG_FILE"
		exit 1
	fi

	# Load configuration from project.toml
	OUTPUT_DIR=$(get_config "paths.output_dir")
	INPUT_DIR=$(get_config "paths.input_dir")
	F5_TTS_MODEL=$(get_config "f5_tts_settings.model")
	CUR_PYTHON_PATH=$(get_config "paths.python_path")

	# Collect PDF names and check polished directories
	local -a pdf_files=()
	mapfile -t pdf_files < <(find "$INPUT_DIR" -type f -name "*.pdf" -exec basename {} .pdf \;)

	if [[ ${#pdf_files[@]} -eq 0 ]]; then
		log_error "No PDF files found in $INPUT_DIR"
		exit 1
	fi
	local concat_path=""
	activate_venv "$CUR_PYTHON_PATH"
	if is_concat "${pdf_files[@]}"; then
		for concat_file_path in "${CONCAT_DIRS_GLOBAL[@]}"; do
			local cleaned_text
			cleaned_text=$(clean_text "$(cat "$concat_file_path/concatenated.txt")")
			if [[ $cleaned_text ]]; then
				echo "SUCCESS: Text has been cleaned up. Ready to chunk"
				print_line
			else
				echo "ERROR: Failed to clean text"
				print_line
				continue
			fi

			wav_file_dir="${OUTPUT_DIR}/$(basename "$(dirname "$concat_file_path")")/wav"
			mkdir -p "$wav_file_dir"
			echo "INFO: Converting text -> chunking -> wav"
			text_chunks_to_wav "$cleaned_text" "$wav_file_dir"

			echo "GOOD"
		done
	fi

}

main "$@"
