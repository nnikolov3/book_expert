#!/usr/bin/env bash
# ================================================================================================
# Script: generate_wav.sh
# Purpose: Converts PDF text to audio chunks using F5-TTS
# Design: Niko Nikolov
# Code: Niko and LLMs
# ================================================================================================

set -euo pipefail

# --- Global Variables ---
declare OUTPUT_DIR_GLOBAL=""
declare INPUT_DIR_GLOBAL=""
declare F5_TTS_MODEL_GLOBAL="E2TTS_Base"
declare -a COMPLETE_DIRS_GLOBAL=()
declare CUR_PYTHON_PATH_GLOBAL=""
declare LOG_FILE_GLOBAL=""
declare LOG_DIR_GLOBAL=""
# ================================================================================================
# UTILITY FUNCTIONS
# ================================================================================================

# Function: create_chunks
# Purpose: Creates semantic chunks from text for TTS processing
# Usage: create_chunks "$cleaned_text" chunks 200
# Parameters:
#   $1 - text: Input text to chunk
#   $2 - chunks_ref: Array reference to store chunks
#   $3 - target_size: Target chunk size in characters (default: 200)
create_chunks()
{
	local text="$1"
	local -n chunks_ref="$2"
	local target_size="${3:-200}"
	local current_chunk=""
	local IFS=$'\n'
	local -a sentences=()
	local line=""
	local sentence=""

	log_info "Creating semantic chunks (target size: $target_size)"
	chunks_ref=()

	# Split text on sentence boundaries (. ? ! followed by space)
	while IFS= read -r line; do
		# Remove leading/trailing whitespace
		line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
		if [[ -n $line ]]; then
			sentences+=("$line")
		fi
	done < <(echo "$text" | sed -E 's/([;:,.!?；：，。！？])[[:space:]]+/\1\n/g')

	# Aggregate sentences into size-limited chunks
	for sentence in "${sentences[@]}"; do
		if [[ -z $sentence ]]; then
			continue
		fi

		# Check if next chunk would exceed target size
		local potential_length=$((${#current_chunk} + ${#sentence} + 1))
		if ((potential_length > target_size)); then
			if [[ -n $current_chunk ]]; then
				chunks_ref+=("$current_chunk")
			fi
			current_chunk="$sentence"
		else
			# Add sentence with space for natural flow
			if [[ -n $current_chunk ]]; then
				current_chunk="$current_chunk $sentence"
			else
				current_chunk="$sentence"
			fi
		fi
	done

	# Add final partial chunk if exists
	if [[ -n $current_chunk ]]; then
		chunks_ref+=("$current_chunk")
	fi

	log_info "Created ${#chunks_ref[@]} semantic chunks"
	return 0
}

# Function: text_chunks_to_wav
# Purpose: Converts text chunks to WAV audio files using F5-TTS
# Parameters:
#   $1 - text: Input text to convert
#   $2 - output_dir: Directory to store WAV files
text_chunks_to_wav()
{
	local text="$1"
	local output_dir="$2"
	local -a text_chunks=()
	local chunk_num=1
	local total_chunks=0
	local preview_length=60
	local failed_chunks=0
	local temp_output=""
	local chunk=""
	local chunk_filename=""
	local chunk_preview=""
	local chunk_length=0
	local full_output_path=""
	local file_size=0
	local successful_chunks=0

	log_info "Starting the creation of text chunks"

	# Validate inputs
	if [[ -z $text ]]; then
		log_error "NO TEXT!"
		return 1
	fi
	log_success "Text found. Chunk now."

	if [[ -z $output_dir ]]; then
		log_error "No output directory specified"
		return 1
	fi

	# Create text chunks
	if ! create_chunks "$text" text_chunks; then
		log_error "Failed to create text chunks"
		return 1
	fi

	total_chunks=${#text_chunks[@]}

	# Validate chunk creation
	if [[ $total_chunks -eq 0 ]]; then
		log_error "No text chunks were created - check input text"
		return 1
	fi

	log_info "Processing $total_chunks chunks"

	# Process each chunk
	for chunk in "${text_chunks[@]}"; do
		# Skip empty chunks
		if [[ -z $chunk ]]; then
			log_warn "Skipping empty chunk $chunk_num"
			chunk_num=$((chunk_num + 1))
			continue
		fi

		printf -v chunk_filename "chunk_%04d.wav" "$chunk_num"
		full_output_path="$output_dir/$chunk_filename"

		# Skip if chunk file already exists
		if [[ -f $full_output_path ]]; then
			log_info "Skipping existing chunk file $chunk_filename"
			chunk_num=$((chunk_num + 1))
			continue
		fi

		chunk_length=${#chunk}

		# Create preview for logging
		if [[ $chunk_length -gt $preview_length ]]; then
			chunk_preview="${chunk:0:preview_length}..."
		else
			chunk_preview="$chunk"
		fi

		# Progress indicator every 10 chunks
		if ((chunk_num % 10 == 0)); then
			log_info "Progress: $chunk_num/$total_chunks chunks completed"
		fi

		# Show chunk info with character count
		log_info "[$chunk_num/$total_chunks] Processing ($chunk_length chars): $chunk_preview"

		# Run F5-TTS with error handling
		temp_output=$(
			f5-tts_infer-cli \
				-m "$F5_TTS_MODEL_GLOBAL" \
				-t "$chunk" \
				-o "$output_dir" \
				-w "$chunk_filename" \
				--remove_silence \
				--load_vocoder_from_local \
				--ref_text "" \
				--no_legacy_text
		)
		local tts_exit_code="$?"

		if [[ $tts_exit_code -eq 0 ]]; then
			# Verify output file was created and has reasonable size
			if [[ -f $full_output_path ]] && [[ -s $full_output_path ]]; then
				file_size=$(stat -c%s "$full_output_path" || echo 0)
				log_info "✅ Created $chunk_filename (${file_size} bytes)"
			else
				log_error "❌ Output file not created or empty for chunk $chunk_num: $chunk_filename"
				failed_chunks=$((failed_chunks + 1))
			fi
		else
			log_error "❌ Failed to process chunk $chunk_num: $chunk_preview"
			if [[ -n $temp_output ]]; then
				log_error "F5-TTS error output: $temp_output"
			fi
			failed_chunks=$((failed_chunks + 1))
		fi

		chunk_num=$((chunk_num + 1))
	done

	successful_chunks=$((total_chunks - failed_chunks))

	if [[ $failed_chunks -gt 0 ]]; then
		log_warn "⚠️  Completed with $failed_chunks failed chunks out of $total_chunks"
	fi

	log_success "✅ Generated $successful_chunks audio chunks in $output_dir"

	# List generated files for verification
	if [[ $successful_chunks -gt 0 ]]; then
		log_info "Generated files:"
		find "$output_dir" -name "chunk_*.wav" -type f -printf "  %f (%s bytes)\n" | head -10
		if [[ $successful_chunks -gt 10 ]]; then
			log_info "  ... and $((successful_chunks - 10)) more files"
		fi
	fi

	if [[ $successful_chunks -gt 0 ]]; then
		return 0
	else
		return 1
	fi
}

# Function: clean_and_store_text
# Purpose: Cleans text from input file and stores in final_complete directory
# Parameters:
#   $1 - input_file: Source text file to clean
#   $2 - output_file: Destination for cleaned text
clean_and_store_text()
{
	local input_file="$1"
	local output_file="$2"
	local cleaned_text=""
	local output_dir=""
	local file_size=0

	log_info "Cleaning text from: $input_file"
	log_info "Output file: $output_file"

	# Validate input file exists
	if [[ ! -f $input_file ]]; then
		log_error "Input file not found: $input_file"
		return 1
	fi

	# Create output directory if needed
	output_dir=$(dirname "$output_file")
	if [[ ! -d $output_dir ]]; then
		mkdir -p "$output_dir"
		log_info "Created directory: $output_dir"
	fi

	# Clean the text using helper script
	cleaned_text=$(./helpers/clean_text_helper.sh <"$input_file")
	local -r clean_exit_code="$?"

	if [[ $clean_exit_code -eq 0 ]]; then
		# Validate cleaning produced output
		if [[ -z $cleaned_text ]]; then
			log_error "Text cleaning resulted in empty output"
			return 1
		fi

		# Write cleaned text to output file
		echo "$cleaned_text" >"$output_file"

		# Verify file was written successfully
		if [[ -f $output_file ]] && [[ -s $output_file ]]; then
			file_size=$(stat -c%s "$output_file" || echo 0)
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

# Function: is_complete
# Purpose: Checks for complete text files and populates global array
# Parameters:
#   $@ - pdf_array: Array of PDF names to check
is_complete()
{
	local -a pdf_array=("$@")
	local pdf_name=""
	local complete_path=""
	local complete_count=0

	COMPLETE_DIRS_GLOBAL=()

	for pdf_name in "${pdf_array[@]}"; do
		log_info "Checking document: $pdf_name"
		complete_path="${OUTPUT_DIR_GLOBAL}/${pdf_name}/complete"

		if [[ -d $complete_path ]]; then
			complete_count=$(find "$complete_path" -type f | wc -l)
			if [[ $complete_count -eq 1 ]]; then
				log_success "Found $complete_count file to process"
				COMPLETE_DIRS_GLOBAL+=("$complete_path")
			else
				log_warn "Review $complete_path , no file found"
			fi
		else
			log_warn "Confirm $complete_path"
		fi
	done

	if [[ ${#COMPLETE_DIRS_GLOBAL[@]} -eq 0 ]]; then
		log_error "No directories with complete text file."
		exit 1
	fi

	log_success "Found directories to process"
	return 0
}

# ================================================================================================
# MAIN EXECUTION
# ================================================================================================

# Function: main
# Purpose: Main script execution logic
# Parameters:
#   $@ - Command line arguments
main()
{
	local -a pdf_files=()
	local complete_file_path=""
	local pdf_name=""
	local input_complete_file=""
	local final_complete_dir=""
	local final_complete_file=""
	local wav_file_dir=""
	local cleaned_text=""
	local config_helper="helpers/get_config_helper.sh"

	# Load configuration from project.toml
	OUTPUT_DIR_GLOBAL=$($config_helper "paths.output_dir")
	INPUT_DIR_GLOBAL=$($config_helper "paths.input_dir")
	F5_TTS_MODEL_GLOBAL=$($config_helper "f5_tts_settings.model")
	CUR_PYTHON_PATH_GLOBAL=$($config_helper "paths.python_path")
	LOG_DIR_GLOBAL=$($config_helper "logs_dir.text_to_wav")

	mkdir -p "$LOG_DIR_GLOBAL"
	LOG_FILE_GLOBAL="$LOG_DIR_GLOBAL/log_$(date +'%Y%m%d_%H%M%S').log"
	touch "$LOG_FILE_GLOBAL"
	local activate_status
	activate_status=$(source "${CUR_PYTHON_PATH_GLOBAL}/activate")
	# Activate Python virtual environment
	if [[ $activate_status -ne 0 ]]; then
		log_error "Failed to activate virtual environment"
		exit 1
	fi

	# Source logging utilities
	local -r logger="helpers/logging_utils_helper.sh"
	source "$logger"

	# Collect PDF files from input directory
	mapfile -t pdf_files < <(find "$INPUT_DIR_GLOBAL" -type f -name "*.pdf" -exec basename {} .pdf \;)

	if [[ ${#pdf_files[@]} -eq 0 ]]; then
		log_error "No PDF files found in $INPUT_DIR_GLOBAL"
		exit 1
	fi

	# Check for completeenated files and process them
	if is_complete "${pdf_files[@]}"; then
		for complete_file_path in "${COMPLETE_DIRS_GLOBAL[@]}"; do
			# Extract PDF name from path (parent of complete directory)
			pdf_name=$(basename "$(dirname "$complete_file_path")")
			input_complete_file="$complete_file_path/complete.txt"
			final_complete_dir="${OUTPUT_DIR_GLOBAL}/${pdf_name}/final_complete"
			final_complete_file="$final_complete_dir/final_text.txt"
			wav_file_dir="${OUTPUT_DIR_GLOBAL}/${pdf_name}/wav"

			log_info "Processing PDF: $pdf_name"

			# Step 1: Clean text and store in final_complete directory
			if clean_and_store_text "$input_complete_file" "$final_complete_file"; then
				log_success "✅ Text cleaned and stored in: $final_complete_file"
			else
				log_error "❌ Failed to clean and store text for: $pdf_name"
				continue
			fi

			# Step 2: Create wav directory and convert to audio chunks
			mkdir -p "$wav_file_dir"
			log_info "Converting cleaned text -> chunking -> wav files"

			# Read the cleaned text from the stored file
			cleaned_text=$(cat "$final_complete_file")
			local -r cat_exit_code="$?"

			if [[ $cat_exit_code -eq 0 ]]; then
				if text_chunks_to_wav "$cleaned_text" "$wav_file_dir"; then
					log_success "✅ Audio conversion completed for: $pdf_name"
				else
					log_error "❌ Audio conversion failed for: $pdf_name"
				fi
			else
				log_error "❌ Failed to read cleaned text from: $final_complete_file"
				continue
			fi
		done
	fi
}

main "$@"
