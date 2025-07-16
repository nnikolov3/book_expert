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
# COMMENTS SHOULD NOT BE REMOVED, INCONCISTENCIES SHOULD BE UPDATED WHEN DETECTED
# USE MARKDOWN WITHIN THE COMMENT BLOCKS FOR COMMENTS
# ===============================================================================================
set -euo pipefail

# --- Configuration ---
declare -r CONFIG_FILE="project.toml"

# --- Global Variables ---
declare OUTPUT_DIR INPUT_DIR PROCESSING_BASE_DIR
declare F5_TTS_MODEL WORKERS MAX_RETRIES RETRY_DELAY GENERATED_DIR_NAME TIMEOUT_DURATION
declare PDF_NAME PROCESSING_DIR CHUNKS_DIR_IN_PROCESSING LOG_DIR FAILED_FILES_DIR GENERATED_WAVS_DIR
declare PROCESSED_COUNT_FILE SUCCESS_COUNT_FILE FAILED_COUNT_FILE

# ================================================================================================
# UTILITY FUNCTIONS
# ================================================================================================

# ## get_config()
# Loads configuration from `project.toml`.
get_config()
{
	yq -r ".${1}" "$CONFIG_FILE"
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

# ## cleanup_processing_dir()
# Cleans up the main processing directory on successful completion.
cleanup_processing_dir()
{
	if [[ -n ${PROCESSING_DIR:-} && -d $PROCESSING_DIR ]]; then
		log_info "Removing successfully completed processing directory: $PROCESSING_DIR"
		rm -rf "$PROCESSING_DIR" || log_error "Failed to remove $PROCESSING_DIR"
	fi
}

# ## check_polished_directories()
# Collects all PDF files in INPUT_DIR and checks for the existence of a polished directory
# (OUTPUT_DIR/pdf_name/polished) containing .txt files.
# Outputs the results for each PDF.
check_polished_directories()
{
	log_info "Checking for polished directories in $OUTPUT_DIR"

	local -a pdf_files=()
	mapfile -t pdf_files < <(find "$INPUT_DIR" -maxdepth 1 -name "*.pdf" -type f | sort) || {
		log_info "Failed to find PDF files in $INPUT_DIR"
		return 0
	}

	if [[ ${#pdf_files[@]} -eq 0 ]]; then
		log_info "No PDF files found in $INPUT_DIR"
		return 0
	fi

	log_info "Found ${#pdf_files[@]} PDF files. Checking polished directories..."
	for pdf_file in "${pdf_files[@]}"; do
		local pdf_name
		pdf_name=$(basename "$pdf_file" .pdf)
		local polished_dir="$OUTPUT_DIR/$pdf_name/polished"

		if [[ -d $polished_dir ]]; then
			local txt_count
			txt_count=$(find "$polished_dir" -maxdepth 1 -name "*.txt" -type f -printf '.' | wc -c) || {
				log_error "Failed to count .txt files in $polished_dir"
				continue
			}
			if [[ $txt_count -gt 0 ]]; then
				log_info "PDF: $pdf_name - Polished directory exists with $txt_count .txt files"
			else
				log_info "PDF: $pdf_name - Polished directory exists but contains no .txt files"
			fi
		else
			log_info "PDF: $pdf_name - Polished directory does not exist"
		fi
	done
}

# ================================================================================================
# PROCESSING FUNCTIONS
# ================================================================================================

# ## process_chunk_block()
# Core worker function to process a block of text chunks into WAV files using F5-TTS.
# Parameters: Worker ID, source directory, chunk list file.
process_chunk_block()
{
	local worker_id="$1"
	local source_dir="$2"
	local chunk_list_file="$3"
	local worker_log="$LOG_DIR/worker_$worker_id.log"
	local worker_tmp_dir="$PROCESSING_DIR/worker_tmp_$worker_id"
	mkdir -p "$worker_tmp_dir" || {
		log_error "Worker $worker_id: Failed to create temporary directory $worker_tmp_dir"
		return 1
	}

	log_info "Worker $worker_id started processing from $source_dir (List: $chunk_list_file)." | tee -a "$worker_log"

	# Assign GPU to worker if multiple GPUs are available
	if command -v nvidia-smi &>/dev/null; then
		local gpu_count
		gpu_count=$(nvidia-smi --query-gpu=count --format=csv,noheader,nounits | head -1 | tr -d '[:space:]' || echo 1)
		if [[ $gpu_count -gt 1 ]]; then
			export CUDA_VISIBLE_DEVICES=$((worker_id % gpu_count))
			echo "Worker $worker_id: Assigned to GPU $CUDA_VISIBLE_DEVICES" >>"$worker_log"
		fi
	fi

	while IFS= read -r chunk_path || [[ -n $chunk_path ]]; do
		if [[ ! -f $chunk_path ]]; then
			echo "Worker $worker_id: Chunk file not found (already processed or moved): $chunk_path" >>"$worker_log"
			continue
		fi

		local base_name
		base_name=$(basename "$chunk_path" .txt)
		local wav_file="$GENERATED_WAVS_DIR/$base_name.wav"
		local f5_log="$LOG_DIR/f5_${base_name}_worker${worker_id}.log"
		local temp_output_dir="$worker_tmp_dir/$base_name"
		mkdir -p "$temp_output_dir" || {
			echo "Worker $worker_id: Failed to create $temp_output_dir" >>"$worker_log"
			continue
		}

		echo "Worker $worker_id: Processing $base_name" >>"$worker_log"

		# Validate text content
		if [[ "$(<"$chunk_path")" =~ ^[[:space:]]*$ ]]; then
			echo "Worker $worker_id: Skipping empty file $base_name" >>"$worker_log"
			rm -f "$chunk_path" || echo "Worker $worker_id: Failed to remove empty file $chunk_path" >>"$worker_log"
			rm -rf "$temp_output_dir" || echo "Worker $worker_id: Failed to remove $temp_output_dir" >>"$worker_log"
			flock "$SUCCESS_COUNT_FILE" bash -c "echo \$(( \$(cat \"$SUCCESS_COUNT_FILE\") + 1 )) > \"$SUCCESS_COUNT_FILE\"" || {
				echo "Worker $worker_id: Failed to update success counter" >>"$worker_log"
			}
			flock "$PROCESSED_COUNT_FILE" bash -c "echo \$(( \$(cat \"$PROCESSED_COUNT_FILE\") + 1 )) > \"$PROCESSED_COUNT_FILE\"" || {
				echo "Worker $worker_id: Failed to update processed counter" >>"$worker_log"
			}
			continue
		fi

		# Run F5-TTS with timeout
		if timeout "$TIMEOUT_DURATION" bash -c "source /home/niko/Dev/book_expert/.venv/bin/activate && f5-tts_infer-cli -m \"$F5_TTS_MODEL\" -f \"$chunk_path\" -o \"$temp_output_dir\" --no_legacy_text" >"$f5_log" 2>&1; then
			local generated_wav
			generated_wav=$(find "$temp_output_dir" -name "*.wav" -type f -print -quit) || {
				echo "Worker $worker_id: Failed to find generated WAV in $temp_output_dir" >>"$worker_log"
				mv "$chunk_path" "$FAILED_FILES_DIR/" || echo "Worker $worker_id: Failed to move $chunk_path to $FAILED_FILES_DIR" >>"$worker_log"
				flock "$FAILED_COUNT_FILE" bash -c "echo \$(( \$(cat \"$FAILED_COUNT_FILE\") + 1 )) > \"$FAILED_COUNT_FILE\"" || echo "Worker $worker_id: Failed to update failed counter" >>"$worker_log"
				continue
			}
			if [[ -n $generated_wav ]]; then
				mv "$generated_wav" "$wav_file" || {
					echo "Worker $worker_id: Failed to move $generated_wav to $wav_file" >>"$worker_log"
					mv "$chunk_path" "$FAILED_FILES_DIR/" || echo "Worker $worker_id: Failed to move $chunk_path to $FAILED_FILES_DIR" >>"$worker_log"
					flock "$FAILED_COUNT_FILE" bash -c "echo \$(( \$(cat \"$FAILED_COUNT_FILE\") + 1 )) > \"$FAILED_COUNT_FILE\"" || echo "Worker $worker_id: Failed to update failed counter" >>"$worker_log"
					continue
				}
				echo "Worker $worker_id: Success for $base_name" >>"$worker_log"
				rm -f "$chunk_path" || echo "Worker $worker_id: Failed to remove $chunk_path" >>"$worker_log"
				flock "$SUCCESS_COUNT_FILE" bash -c "echo \$(( \$(cat \"$SUCCESS_COUNT_FILE\") + 1 )) > \"$SUCCESS_COUNT_FILE\"" || echo "Worker $worker_id: Failed to update success counter" >>"$worker_log"
			else
				echo "Worker $worker_id: FAILED (no WAV generated) for $base_name. Log: $f5_log" >>"$worker_log"
				mv "$chunk_path" "$FAILED_FILES_DIR/" || echo "Worker $worker_id: Failed to move $chunk_path to $FAILED_FILES_DIR" >>"$worker_log"
				flock "$FAILED_COUNT_FILE" bash -c "echo \$(( \$(cat \"$FAILED_COUNT_FILE\") + 1 )) > \"$FAILED_COUNT_FILE\"" || echo "Worker $worker_id: Failed to update failed counter" >>"$worker_log"
			fi
		else
			echo "Worker $worker_id: FAILED (timeout/error) for $base_name. Log: $f5_log" >>"$worker_log"
			mv "$chunk_path" "$FAILED_FILES_DIR/" || echo "Worker $worker_id: Failed to move $chunk_path to $FAILED_FILES_DIR" >>"$worker_log"
			flock "$FAILED_COUNT_FILE" bash -c "echo \$(( \$(cat \"$FAILED_COUNT_FILE\") + 1 )) > \"$FAILED_COUNT_FILE\"" || echo "Worker $worker_id: Failed to update failed counter" >>"$worker_log"
		fi

		rm -rf "$temp_output_dir" || echo "Worker $worker_id: Failed to remove $temp_output_dir" >>"$worker_log"
		flock "$PROCESSED_COUNT_FILE" bash -c "echo \$(( \$(cat \"$PROCESSED_COUNT_FILE\") + 1 )) > \"$PROCESSED_COUNT_FILE\"" || echo "Worker $worker_id: Failed to update processed counter" >>"$worker_log"
	done <"$chunk_list_file"

	rm -rf "$worker_tmp_dir" || log_error "Worker $worker_id: Failed to remove $worker_tmp_dir"
	log_info "Worker $worker_id finished processing."
}

# ## orchestrate_processing()
# Divides files among workers and manages their execution.
# Parameters: Directory containing chunk files.
orchestrate_processing()
{
	local target_dir="$1"
	log_info "Orchestrating processing for chunks in: $target_dir"

	local -a chunk_files=()
	mapfile -t chunk_files < <(find "$target_dir" -maxdepth 1 -name "*.txt" -type f | sort) || {
		log_error "Failed to find chunk files in $target_dir"
		return 1
	}

	local total_chunks="${#chunk_files[@]}"
	if [[ $total_chunks -eq 0 ]]; then
		log_info "No chunk files found in $target_dir for processing."
		return 0
	fi

	log_info "Found $total_chunks chunks to process in $target_dir."

	local chunks_per_worker=$(((total_chunks + WORKERS - 1) / WORKERS))
	local -a pids=()
	local chunk_index=0

	for worker_id in $(seq 0 $((WORKERS - 1))); do
		local worker_chunk_list="$PROCESSING_DIR/worker_${worker_id}_chunks.list"
		local end_index=$((chunk_index + chunks_per_worker))

		local -a worker_chunks=()
		for ((i = chunk_index; i < end_index && i < total_chunks; i++)); do
			worker_chunks+=("${chunk_files[i]}")
		done

		if [[ ${#worker_chunks[@]} -eq 0 ]]; then
			log_info "Worker $worker_id has no chunks assigned."
			continue
		fi

		printf "%s\n" "${worker_chunks[@]}" >"$worker_chunk_list" || {
			log_error "Failed to create chunk list $worker_chunk_list"
			continue
		}
		log_info "Worker $worker_id assigned ${#worker_chunks[@]} chunks."
		process_chunk_block "$worker_id" "$target_dir" "$worker_chunk_list" &
		pids+=($!)
		chunk_index=$end_index
	done

	for pid in "${pids[@]}"; do
		wait "$pid" || log_error "Worker process $pid failed"
	done
	log_info "All workers finished for current batch."

	rm -f "$PROCESSING_DIR"/worker_*.list || log_error "Failed to remove worker chunk lists"
}

# ## run_retries()
# Manages the retry loop for failed text chunks.
run_retries()
{
	for ((i = 1; i <= MAX_RETRIES; i++)); do
		local failed_count
		failed_count=$(find "$FAILED_FILES_DIR" -name "*.txt" -type f -printf '.' | wc -c) || {
			log_error "Failed to count failed files in $FAILED_FILES_DIR"
			return 1
		}
		if [[ $failed_count -eq 0 ]]; then
			log_info "No more failed files to retry."
			return 0
		fi

		log_info "--- Starting Retry Attempt $i/$MAX_RETRIES for $failed_count files ---"
		orchestrate_processing "$FAILED_FILES_DIR" || {
			log_error "Retry attempt $i failed"
			return 1
		}

		if [[ $i -lt $MAX_RETRIES ]]; then
			local remaining_failures
			remaining_failures=$(find "$FAILED_FILES_DIR" -name "*.txt" -type f -printf '.' | wc -c) || {
				log_error "Failed to count remaining failed files in $FAILED_FILES_DIR"
				return 1
			}
			if [[ $remaining_failures -gt 0 ]]; then
				log_info "Waiting $RETRY_DELAY seconds before next retry..."
				sleep "$RETRY_DELAY" || {
					log_error "Failed to sleep for $RETRY_DELAY seconds"
					return 1
				}
			fi
		fi
	done
}

# ## process_pdf()
# Processes a single PDF's text chunks into WAV files.
# Parameters: PDF name (without .pdf extension).
# Returns: 0 on success, 1 on failure.
process_pdf()
{
	local pdf_name="$1"
	PDF_NAME="$pdf_name"
	log_info "--- Starting Chunks-to-WAV for PDF: $PDF_NAME ---"

	# Determine the processing directory
	local timestamp
	timestamp=$(date +%Y%m%d%H%M%S) || {
		log_error "Failed to generate timestamp for $PDF_NAME"
		return 1
	}
	local potential_processing_dir="${PROCESSING_BASE_DIR}/${PDF_NAME}"

	local latest_existing_dir=""
	if [[ -d $potential_processing_dir ]]; then
		latest_existing_dir=$(find "$potential_processing_dir" -maxdepth 1 -type d -name "run_*" | sort -r | head -n 1) || {
			log_error "Failed to find existing processing directory for $PDF_NAME"
			return 1
		}
	fi

	if [[ -n $latest_existing_dir && -d "$latest_existing_dir/chunks" && -n "$(find "$latest_existing_dir/chunks" -maxdepth 1 -name "*.txt" -print -quit)" ]]; then
		PROCESSING_DIR="$latest_existing_dir"
		log_info "Resuming processing in existing directory: $PROCESSING_DIR"
	elif [[ -n $latest_existing_dir && -d "$latest_existing_dir/failed_files" && -n "$(find "$latest_existing_dir/failed_files" -maxdepth 1 -name "*.txt" -print -quit)" ]]; then
		PROCESSING_DIR="$latest_existing_dir"
		log_info "Resuming processing failed files in existing directory: $PROCESSING_DIR"
	else
		PROCESSING_DIR="${potential_processing_dir}/run_${timestamp}"
		log_info "Creating new processing directory: $PROCESSING_DIR"
	fi

	# Setup directories
	CHUNKS_DIR_IN_PROCESSING="$PROCESSING_DIR/chunks"
	GENERATED_WAVS_DIR="$PROCESSING_DIR/$GENERATED_DIR_NAME"
	LOG_DIR="$PROCESSING_DIR/logs"
	FAILED_FILES_DIR="$PROCESSING_DIR/failed_files"
	mkdir -p "$CHUNKS_DIR_IN_PROCESSING" "$GENERATED_WAVS_DIR" "$LOG_DIR" "$FAILED_FILES_DIR" || {
		log_error "Failed to create directories for $PDF_NAME: $PROCESSING_DIR"
		return 1
	}

	# Copy original chunks if this is a new run
	local ORIGINAL_CHUNKS_SOURCE="$OUTPUT_DIR/$PDF_NAME/tts_chunks"
	if [[ ! -d $ORIGINAL_CHUNKS_SOURCE ]]; then
		log_error "Original chunk source directory not found: $ORIGINAL_CHUNKS_SOURCE"
		return 1
	fi
	if [[ ! -d $CHUNKS_DIR_IN_PROCESSING || -z "$(find "$CHUNKS_DIR_IN_PROCESSING" -maxdepth 1 -name "*.txt" -print -quit)" ]]; then
		local initial_chunk_count
		initial_chunk_count=$(find "$ORIGINAL_CHUNKS_SOURCE" -name "*.txt" -type f -printf '.' | wc -c) || {
			log_error "Failed to count chunks in $ORIGINAL_CHUNKS_SOURCE"
			return 1
		}
		if [[ $initial_chunk_count -eq 0 ]]; then
			log_error "No .txt chunk files found in $ORIGINAL_CHUNKS_SOURCE"
			return 1
		fi
		log_info "Staging $initial_chunk_count chunks from original source to processing directory: $CHUNKS_DIR_IN_PROCESSING"
		rsync -a "$ORIGINAL_CHUNKS_SOURCE/"*.txt "$CHUNKS_DIR_IN_PROCESSING/" || {
			log_error "Failed to stage chunks to $CHUNKS_DIR_IN_PROCESSING"
			return 1
		}
	else
		log_info "Chunks already staged in $CHUNKS_DIR_IN_PROCESSING. Resuming..."
	fi

	# Initialize counters
	PROCESSED_COUNT_FILE="$PROCESSING_DIR/processed_count"
	SUCCESS_COUNT_FILE="$PROCESSING_DIR/success_count"
	FAILED_COUNT_FILE="$PROCESSING_DIR/failed_count"

	if [[ -d $PROCESSING_DIR ]]; then
		if [[ ! -f $PROCESSED_COUNT_FILE || ! -f $SUCCESS_COUNT_FILE || ! -f $FAILED_COUNT_FILE ]]; then
			log_info "Incomplete counter files in $PROCESSING_DIR. Resetting counters for new run."
			echo 0 >"$PROCESSED_COUNT_FILE" || {
				log_error "Failed to initialize $PROCESSED_COUNT_FILE"
				return 1
			}
			echo 0 >"$SUCCESS_COUNT_FILE" || {
				log_error "Failed to initialize $SUCCESS_COUNT_FILE"
				return 1
			}
			echo 0 >"$FAILED_COUNT_FILE" || {
				log_error "Failed to initialize $FAILED_COUNT_FILE"
				return 1
			}
		else
			local processed_count success_count failed_count
			processed_count=$(cat "$PROCESSED_COUNT_FILE") || {
				log_error "Failed to read $PROCESSED_COUNT_FILE"
				return 1
			}
			success_count=$(cat "$SUCCESS_COUNT_FILE") || {
				log_error "Failed to read $SUCCESS_COUNT_FILE"
				return 1
			}
			failed_count=$(cat "$FAILED_COUNT_FILE") || {
				log_error "Failed to read $FAILED_COUNT_FILE"
				return 1
			}
			log_info "Resuming with counters: Processed=$processed_count, Success=$success_count, Failed=$failed_count"
			local current_wav_count current_failed_count
			current_wav_count=$(find "$GENERATED_WAVS_DIR" -name "*.wav" -type f -printf '.' | wc -c) || {
				log_error "Failed to count WAV files in $GENERATED_WAVS_DIR"
				return 1
			}
			current_failed_count=$(find "$FAILED_FILES_DIR" -name "*.txt" -type f -printf '.' | wc -c) || {
				log_error "Failed to count failed files in $FAILED_FILES_DIR"
				return 1
			}
			if [[ $success_count -ne $current_wav_count || $failed_count -ne $current_failed_count ]]; then
				log_error "Counter mismatch: Success count ($success_count) != WAV files ($current_wav_count) or Failed count ($failed_count) != Failed files ($current_failed_count)"
				return 1
			fi
		fi
	else
		echo 0 >"$PROCESSED_COUNT_FILE" || {
			log_error "Failed to initialize $PROCESSED_COUNT_FILE"
			return 1
		}
		echo 0 >"$SUCCESS_COUNT_FILE" || {
			log_error "Failed to initialize $SUCCESS_COUNT_FILE"
			return 1
		}
		echo 0 >"$FAILED_COUNT_FILE" || {
			log_error "Failed to initialize $FAILED_COUNT_FILE"
			return 1
		}
	fi

	# Initial processing run
	local remaining_initial_chunks
	remaining_initial_chunks=$(find "$CHUNKS_DIR_IN_PROCESSING" -name "*.txt" -type f -printf '.' | wc -c) || {
		log_error "Failed to count remaining chunks in $CHUNKS_DIR_IN_PROCESSING"
		return 1
	}
	if [[ $remaining_initial_chunks -gt 0 ]]; then
		log_info "Starting initial processing for $remaining_initial_chunks remaining chunks..."
		orchestrate_processing "$CHUNKS_DIR_IN_PROCESSING" || {
			log_error "Initial processing failed for $PDF_NAME"
			return 1
		}
	else
		log_info "Initial chunk directory is empty or all files processed. Skipping initial pass."
	fi

	# Retry failed files
	run_retries || {
		log_error "Retry processing failed for $PDF_NAME"
		return 1
	}

	# Final validation and copy
	local initial_total_chunks
	initial_total_chunks=$(find "$ORIGINAL_CHUNKS_SOURCE" -name "*.txt" -type f -printf '.' | wc -c) || {
		log_error "Failed to count total chunks in $ORIGINAL_CHUNKS_SOURCE"
		return 1
	}

	local final_success_count
	final_success_count=$(find "$GENERATED_WAVS_DIR" -name "*.wav" -type f -printf '.' | wc -c) || {
		log_error "Failed to count WAV files in $GENERATED_WAVS_DIR"
		return 1
	}
	log_info "Total WAV files generated: $final_success_count / $initial_total_chunks"

	local final_failed_count
	final_failed_count=$(find "$FAILED_FILES_DIR" -name "*.txt" -type f -printf '.' | wc -c) || {
		log_error "Failed to count failed files in $FAILED_FILES_DIR"
		return 1
	}

	local remaining_chunks_in_processing
	remaining_chunks_in_processing=$(find "$CHUNKS_DIR_IN_PROCESSING" -name "*.txt" -type f -printf '.' | wc -c) || {
		log_error "Failed to count remaining chunks in $CHUNKS_DIR_IN_PROCESSING"
		return 1
	}

	if [[ $remaining_chunks_in_processing -eq 0 && $final_failed_count -eq 0 && $final_success_count -eq $initial_total_chunks ]]; then
		log_info "All text chunks successfully processed."
		if [[ $final_success_count -gt 0 ]]; then
			local OUTPUT_WAVS_DIR="$OUTPUT_DIR/$PDF_NAME/$GENERATED_DIR_NAME"
			mkdir -p "$OUTPUT_WAVS_DIR" || {
				log_error "Failed to create $OUTPUT_WAVS_DIR"
				return 1
			}
			log_info "Copying $final_success_count WAV files to permanent storage: $OUTPUT_WAVS_DIR"
			rsync -a --info=progress2 "$GENERATED_WAVS_DIR/" "$OUTPUT_WAVS_DIR/" || {
				log_error "Failed to copy WAV files to $OUTPUT_WAVS_DIR"
				return 1
			}
		fi

		# Save logs
		local FINAL_LOG_DIR="$OUTPUT_DIR/$PDF_NAME/logs"
		mkdir -p "$FINAL_LOG_DIR" || {
			log_error "Failed to create $FINAL_LOG_DIR"
			return 1
		}
		if [[ -n "$(find "$LOG_DIR" -maxdepth 1 -type f)" ]]; then
			cp -r "$LOG_DIR"/* "$FINAL_LOG_DIR/" || {
				log_error "Failed to copy logs from $LOG_DIR to $FINAL_LOG_DIR"
				return 1
			}
		else
			log_info "No logs found in $LOG_DIR to copy."
		fi
		log_info "Logs saved to $FINAL_LOG_DIR"

		log_info "Final validation: All processing and failed directories are empty, and all chunks converted to WAV."
		cleanup_processing_dir
		return 0
	else
		log_error "Processing completed with errors or incomplete results."
		log_error "Remaining chunks in processing directory: $remaining_chunks_in_processing"
		log_error "Remaining failed chunks: $final_failed_count"
		log_error "Generated WAV files: $final_success_count / $initial_total_chunks"
		log_info "Processing directory: $PROCESSING_DIR remains for investigation or resumption."
		return 1
	fi
}

# ================================================================================================
# MAIN EXECUTION
# ================================================================================================
# ================================================================================================
# MAIN EXECUTION
# ================================================================================================
main()
{
	# Check for root privileges
	if [[ $EUID -eq 0 ]]; then
		log_info "Warning: Script is running as root. This is not recommended unless necessary for GPU access or directory permissions."
	fi

	# Check configuration file
	if [[ ! -f $CONFIG_FILE ]]; then
		log_error "Config file not found: $CONFIG_FILE"
		exit 1
	fi

	# Load configuration from project.toml
	OUTPUT_DIR=$(get_config "paths.output_dir") || {
		log_error "Failed to load output_dir from $CONFIG_FILE"
		exit 1
	}
	INPUT_DIR=$(get_config "paths.input_dir") || {
		log_error "Failed to load input_dir from $CONFIG_FILE"
		exit 1
	}
	PROCESSING_BASE_DIR=$(get_config "processing_dir.chunks_to_wav") || {
		log_error "Failed to load processing_dir.chunks_to_wav from $CONFIG_FILE"
		exit 1
	}
	F5_TTS_MODEL=$(get_config "f5_tts_settings.model") || {
		log_error "Failed to load f5_tts_settings.model from $CONFIG_FILE"
		exit 1
	}
	WORKERS=$(get_config "f5_tts_settings.workers") || {
		log_error "Failed to load f5_tts_settings.workers from $CONFIG_FILE"
		exit 1
	}
	MAX_RETRIES=$(get_config "retry.max_retries") || {
		log_error "Failed to load retry.max_retries from $CONFIG_FILE"
		exit 1
	}
	RETRY_DELAY=$(get_config "retry.retry_delay_seconds") || {
		log_error "Failed to load retry.retry_delay_seconds from $CONFIG_FILE"
		exit 1
	}
	GENERATED_DIR_NAME=$(get_config "directories.wav") || {
		log_error "Failed to load directories.wav from $CONFIG_FILE"
		exit 1
	}
	TIMEOUT_DURATION=$(get_config "f5_tts_settings.timeout_duration") || {
		log_error "Failed to load f5_tts_settings.timeout_duration from $CONFIG_FILE"
		exit 1
	}

	mkdir -p "$PROCESSING_BASE_DIR" || {
		log_error "Failed to create $PROCESSING_BASE_DIR"
		exit 1
	}
	# Check write permissions for key directories
	for dir in "$OUTPUT_DIR" "$PROCESSING_BASE_DIR" "$INPUT_DIR"; do
		if [[ ! -w $dir ]]; then
			log_error "Write permission denied for directory: $dir"
			exit 1
		fi
	done

	# Collect PDF names and check polished directories
	local -a pdf_files=()
	mapfile -t pdf_files < <(find "$INPUT_DIR" -maxdepth 1 -name "*.pdf" -type f | sort) || {
		log_error "Failed to find PDF files in $INPUT_DIR"
		exit 1
	}

	if [[ ${#pdf_files[@]} -eq 0 ]]; then
		log_error "No PDF files found in $INPUT_DIR"
		exit 1
	fi

	check_polished_directories

	# Collect PDFs with valid tts_chunks directories
	local -a valid_pdf_names=()
	for pdf_file in "${pdf_files[@]}"; do
		local pdf_name
		pdf_name=$(basename "$pdf_file" .pdf)
		local tts_chunks_dir="$OUTPUT_DIR/$pdf_name/tts_chunks"
		if [[ -d $tts_chunks_dir && -n "$(find "$tts_chunks_dir" -maxdepth 1 -name "*.txt" -type f -print -quit)" ]]; then
			valid_pdf_names+=("$pdf_name")
		else
			log_error "Skipping PDF '$pdf_name': tts_chunks directory not found or empty: $tts_chunks_dir"
		fi
	done

	# Process a single PDF if specified, or all valid PDFs otherwise
	local -a pdf_names=()
	if [[ $# -gt 0 ]]; then
		local pdf_file="$INPUT_DIR/$1.pdf"
		local pdf_name="$1"
		local tts_chunks_dir="$OUTPUT_DIR/$pdf_name/tts_chunks"
		if [[ -f $pdf_file && -d $tts_chunks_dir && -n "$(find "$tts_chunks_dir" -maxdepth 1 -name "*.txt" -type f -print -quit)" ]]; then
			pdf_names=("$pdf_name")
		else
			log_error "Specified PDF '$pdf_name' not found or has no valid tts_chunks directory: $tts_chunks_dir"
			exit 1
		fi
	else
		pdf_names=("${valid_pdf_names[@]}")
	fi

	if [[ ${#pdf_names[@]} -eq 0 ]]; then
		log_error "No PDFs with valid tts_chunks directories found to process."
		exit 1
	fi

	local processed_any=false
	local failed_pdfs=0
	for pdf_name in "${pdf_names[@]}"; do
		log_info "Processing PDF: $pdf_name"
		if process_pdf "$pdf_name"; then
			processed_any=true
		else
			((failed_pdfs++))
			log_error "Failed to process PDF '$pdf_name'"
		fi
	done

	if [[ $processed_any == true ]]; then
		log_info "Script completed with some successful PDF processing ($failed_pdfs failed)."
		exit 0
	else
		log_error "No PDFs were successfully processed ($failed_pdfs failed)."
		exit 1
	fi
}

main "$@"
