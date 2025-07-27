#!/usr/bin/env bash
# ================================================================================================

# Design: Niko Nikolov
# Code: Niko and Various LLMs

set -euo pipefail

# --- Configuration ---
declare -r CONFIG_FILE="$PWD/project.toml"

# --- Global Variables ---
declare OUTPUT_DIR=""
declare INPUT_DIR=""
declare F5_TTS_MODEL="E2TTS_Base"
declare -a CONCAT_DIRS_GLOBAL=()
declare CUR_PYTHON_PATH=""
declare LOG_FILE=""
declare LOG_DIR=""

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

# Usage: create_chunks "$cleaned_text" chunks 200
# chunks will be an array of semantically meaningful strings for TTS
create_chunks()
{
	local text="$1"
	local -n chunks_ref="$2"
	local target_size="${3:-200}" # Target chunk size (characters)
	local current_chunk=""
	local IFS=$'\n'
	local sentences=()

	log_info "Creating semantic chunks (target size: $target_size)"
	chunks_ref=()

	# 1. Split text on . ? ! followed by space (robust "sentence" split)
	while IFS= read -r line; do
		# Remove leading/trailing whitespace
		line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
		[[ -z $line ]] && continue
		sentences+=("$line")
	done < <(echo "$text" | sed -E 's/([.?!]) /\1\n/g')

	# 2. Aggregate sentences into size-limited chunks
	for sentence in "${sentences[@]}"; do
		[[ -z $sentence ]] && continue
		# Next chunk would be too big? Flush.
		if ((${#current_chunk} + ${#sentence} + 1 > target_size)); then
			if [[ -n $current_chunk ]]; then
				# Avoid tiny chunks if possible
				chunks_ref+=("$current_chunk")
			fi
			current_chunk="$sentence"
		else
			# Add with space for natural flow
			current_chunk="${current_chunk:+$current_chunk }$sentence"
		fi
	done

	# 3. Add final partial chunk
	if [[ -n $current_chunk ]]; then
		chunks_ref+=("$current_chunk")
	fi

	log_info "Created ${#chunks_ref[@]} semantic chunks"
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

	log_info "Starting the creation of text chunks"

	# Validate inputs
	if [[ -z $text ]]; then
		log_error "NO TEXT!"
		return 1
	else
		log_success "Text found. Chunk now."
	fi

	if [[ -z $output_dir ]]; then
		log_error "No output directory specified"
		return 1
	fi

	# Call create_chunks with array reference
	if ! create_chunks "$text" text_chunks; then
		log_error "Failed to create text chunks"
		return 1
	fi

	total_chunks=${#text_chunks[@]}

	# Check if we have any chunks
	if [[ $total_chunks -eq 0 ]]; then
		log_error "No text chunks were created - check input text"
		return 1
	fi

	log_info "Processing $total_chunks chunks"

	for chunk in "${text_chunks[@]}"; do
		local chunk_filename
		local chunk_preview
		local chunk_length=${#chunk}
		local full_output_path

		# Skip empty chunks (safety check)
		if [[ -z $chunk ]]; then
			log_warn "Skipping empty chunk $chunk_num"
			chunk_num=$((chunk_num + 1))
			continue
		fi

		printf -v chunk_filename "chunk_%04d.wav" "$chunk_num"
		full_output_path="$output_dir/$chunk_filename"

		# Skip if this chunk's file already exists
		if [[ -f $full_output_path ]]; then
			log_info "Skipping existing chunk file $chunk_filename"
			chunk_num=$((chunk_num + 1))
			continue
		fi

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
			--load_vocoder_from_local \
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
		log_warn "⚠️  Completed with $failed_chunks failed chunks out of $total_chunks" >&2
	fi

	log_success "✅ Generated $successful_chunks audio chunks in $output_dir" >&2

	# List generated files for verification
	if [[ $successful_chunks -gt 0 ]]; then
		log_info "Generated files:" >&2
		find "$output_dir" -name "chunk_*.wav" -type f -printf "  %f (%s bytes)\n" 2>/dev/null | head -10 >&2
		if [[ $successful_chunks -gt 10 ]]; then
			log_info "  ... and $((successful_chunks - 10)) more files" >&2
		fi
	fi

	return "$([[ $successful_chunks -gt 0 ]] && echo 0 || echo 1)"
}

activate_venv()
{
	local venv_path="$1"
	local activate_script="$venv_path/activate"

	if [[ ! -f $activate_script ]]; then
		log_error "Virtual environment not found at $venv_path"
		return 1
	fi

	# shellcheck disable=SC1091
	source "$activate_script"
	log_success "Virtual environment activated"
}

# ## clean_and_store_text()
# Cleans text from input file and stores in final_concat directory
clean_and_store_text()
{
	local input_file="$1"
	local output_file="$2"
	local cleaned_text

	log_info "Cleaning text from: $input_file"
	log_info "Output file: $output_file"

	# Check if input file exists
	if [[ ! -f $input_file ]]; then
		log_error "Input file not found: $input_file"
		return 1
	fi

	# Create output directory if it doesn't exist
	local output_dir
	output_dir=$(dirname "$output_file")
	if [[ ! -d $output_dir ]]; then
		mkdir -p "$output_dir"
		log_info "Created directory: $output_dir"
	fi

	# Clean the text using the cleaning script
	if cleaned_text=$(./clean_text_helper.sh <"$input_file"); then
		# Check if cleaning resulted in non-empty output
		if [[ -z $cleaned_text ]]; then
			log_error "Text cleaning resulted in empty output"
			return 1
		fi

		# Write cleaned text to output file
		echo "$cleaned_text" >"$output_file"

		# Verify the file was written successfully
		if [[ -f $output_file ]] && [[ -s $output_file ]]; then
			local file_size
			file_size=$(stat -c%s "$output_file" 2>/dev/null || echo 0)
			log_success "✅ Cleaned text stored successfully (${file_size} bytes): $output_file"
			return 0
		else
			log_error "Failed to write cleaned text to: $output_file"
			return 1
		fi
	else
		log_error "Text cleaning failed for: $input_file"
		return 1
	fi
}

is_concat()
{
	local -a pdf_array=("$@")
	CONCAT_DIRS_GLOBAL=()

	for pdf_name in "${pdf_array[@]}"; do
		log_info "Checking document: $pdf_name"
		concat_path="${OUTPUT_DIR}/${pdf_name}/concat"
		if [[ -d $concat_path ]]; then
			concat_count=$(find "$concat_path" -type f | wc -l)
			if [[ $concat_count -eq 1 ]]; then
				log_success "Found $concat_count file to process"
				CONCAT_DIRS_GLOBAL+=("$concat_path")
			else
				log_warn "Review $concat_path , no file found"
			fi
		else
			log_warn "Confirm $concat_path"
		fi
	done

	if [ ${#CONCAT_DIRS_GLOBAL[@]} -eq 0 ]; then
		log_error "No directories with concat text file."
		exit 1
	else
		log_success "Found directories to process"
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
		echo "Config file not found: $CONFIG_FILE"
		exit 1
	fi

	# Load configuration from project.toml
	OUTPUT_DIR=$(get_config "paths.output_dir")
	INPUT_DIR=$(get_config "paths.input_dir")
	F5_TTS_MODEL=$(get_config "f5_tts_settings.model")
	CUR_PYTHON_PATH=$(get_config "paths.python_path")
	LOG_DIR=$(get_config "logs_dir.text_to_wav")
	mkdir -p "$LOG_DIR"
	touch "$LOG_DIR/log.txt"
	LOG_FILE="$LOG_DIR/log.txt"
	# Collect PDF names and check polished directories
	local -a pdf_files=()
	mapfile -t pdf_files < <(find "$INPUT_DIR" -type f -name "*.pdf" -exec basename {} .pdf \;)

	if [[ ${#pdf_files[@]} -eq 0 ]]; then
		log_error "No PDF files found in $INPUT_DIR"
		exit 1
	fi

	activate_venv "$CUR_PYTHON_PATH"

	if is_concat "${pdf_files[@]}"; then
		for concat_file_path in "${CONCAT_DIRS_GLOBAL[@]}"; do
			local pdf_name
			local input_concat_file
			local final_concat_dir
			local final_concat_file
			local wav_file_dir

			# Extract PDF name from path (parent of concat directory)
			pdf_name=$(basename "$(dirname "$concat_file_path")")
			input_concat_file="$concat_file_path/concatenated.txt"
			final_concat_dir="${OUTPUT_DIR}/${pdf_name}/final_concat"
			final_concat_file="$final_concat_dir/cleaned_text.txt"
			wav_file_dir="${OUTPUT_DIR}/${pdf_name}/wav"

			log_info "Processing PDF: $pdf_name"

			# Step 1: Clean text and store in final_concat directory
			if clean_and_store_text "$input_concat_file" "$final_concat_file"; then
				log_success "✅ Text cleaned and stored in: $final_concat_file"
			else
				log_error "❌ Failed to clean and store text for: $pdf_name"
				continue
			fi

			# Step 2: Create wav directory and convert to audio chunks
			mkdir -p "$wav_file_dir"
			log_info "Converting cleaned text -> chunking -> wav files"

			# Read the cleaned text from the stored file
			local cleaned_text
			if cleaned_text=$(cat "$final_concat_file"); then
				text_chunks_to_wav "$cleaned_text" "$wav_file_dir"
				log_success "✅ Audio conversion completed for: $pdf_name"
			else
				log_error "❌ Failed to read cleaned text from: $final_concat_file"
				continue
			fi
		done
	fi
}

main "$@"
