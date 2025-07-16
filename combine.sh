#!/usr/bin/env bash
# combine.sh
# Design: Niko Nikolov
# Code: Various LLMs, with fixes by Grok

# ## Code Guidelines:
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
# COMMENTS SHOULD NOT BE REMOVED, INCONSISTENCIES SHOULD BE UPDATED WHEN DETECTED
# USE MARKDOWN WITHIN THE COMMENT BLOCKS FOR COMMENTS
# ===============================================================================================
set -euo pipefail

# --- Configuration ---
# Path to project configuration file
declare CONFIG_FILE="$HOME/Dev/book_expert/project.toml"

# --- Global Variables ---
# Initialize all variables with defaults
declare OUTPUT_DIR="" WAV_DIR_NAME="" TEMP_DIR="" WORKERS=0 \
	LOG_DIR="" LOG_FILE="" FAILED_LOG="" \
	MAX_RETRIES=0 RETRY_DELAY_SECONDS=0
declare -a worker_pids=()
declare cleanup_called=false
declare script_completed=false

# Get configuration value from TOML file
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
		log_error "Failed to read configuration key '$key' from $CONFIG_FILE"
		exit 1
	}
	if [[ -z $value ]]; then
		if [[ -n $default_value ]]; then
			echo "$default_value"
			return 0
		fi
		log_error "Missing required configuration key '$key' in $CONFIG_FILE"
		exit 1
	fi
	echo "$value"
}

# Logging functions with timestamp and file output
log_info()
{
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $*" | tee -a "${LOG_FILE:-/dev/null}"
}
log_error()
{
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >>"${LOG_FILE:-/dev/null}"
	return 1
}
log_debug()
{
	if [[ ${DEBUG:-false} == "true" ]]; then
		echo "[$(date +'%Y-%m-%d %H:%M:%S')] DEBUG: $*" >>"${LOG_FILE:-/dev/null}"
	fi
}

# Check dependencies
check_dependencies()
{
	local deps=("ffmpeg" "rsync" "sort" "yq" "nproc")
	for dep in "${deps[@]}"; do
		if ! command -v "$dep" >/dev/null; then
			log_error "'$dep' is not installed."
			exit 1
		fi
	done
}

# Validate WAV file integrity
validate_wav_file()
{
	local file="$1"
	if [[ ! -f $file ]]; then
		log_error "File does not exist: $file"
		return 1
	fi
	if ! ffmpeg -i "$file" -f null - >/dev/null 2>&1; then
		log_error "Invalid WAV file (ffmpeg failed to process): $file"
		return 1
	fi
	return 0
}

# Check if WAV file needs resampling
needs_resampling()
{
	local file="$1"
	local sample_rate=48000
	local expected_channels=1
	local codec="pcm_s16le"
	local file_info

	# Attempt to get audio info, handle failures gracefully
	file_info=$(ffmpeg -i "$file" 2>&1 | grep 'Audio:' || true)
	if [[ -z $file_info ]]; then
		log_error "Cannot retrieve audio info for $file, assuming resampling needed"
		return 0
	fi
	if [[ $file_info =~ Audio:\ ([^,]+),\ ([0-9]+)\ Hz,\ ([^,]+) ]]; then
		local file_codec="${BASH_REMATCH[1]}"
		local file_rate="${BASH_REMATCH[2]}"
		local file_channels="${BASH_REMATCH[3]}"
		local channel_count
		if [[ $file_channels == "mono" ]]; then
			channel_count=1
		elif [[ $file_channels == "stereo" ]]; then
			channel_count=2
		else
			channel_count=$(echo "$file_channels" | grep -o '[0-9]\+' || echo "0")
		fi
		if [[ $file_codec == "$codec" && $file_rate == "$sample_rate" && $channel_count -eq $expected_channels ]]; then
			log_debug "No resampling needed for $file"
			return 1 # No resampling needed
		fi
		log_debug "Resampling needed for $file (codec: $file_codec, rate: $file_rate, channels: $file_channels, channel_count: $channel_count)"
	fi
	return 0 # Resampling needed
}

# Enhanced file ordering function for WAV concatenation
find_and_sort_wav_files()
{
	local search_dir="$1"
	local -a wav_files sorted_files

	log_info "Searching for WAV files in: $search_dir"

	# Find all WAV files, ensuring output is clean
	mapfile -t wav_files < <(find "$search_dir" -maxdepth 1 -name "*.wav" -type f -print0 | sort -z | tr '\0' '\n')

	if [[ ${#wav_files[@]} -eq 0 ]]; then
		log_error "No WAV files found in directory: $search_dir"
		return 1
	fi

	log_info "Found ${#wav_files[@]} WAV files to sort"

	# Method 1: Try version sort (handles numeric sequences naturally)
	log_debug "Attempting version sort (-V flag)"
	if command -v sort >/dev/null 2>&1; then
		if echo -e "file1\nfile10\nfile2" | sort -V >/dev/null 2>&1; then
			mapfile -t sorted_files < <(printf '%s\n' "${wav_files[@]}" | sort -V)
			log_info "Using version sort for natural ordering"
		else
			log_info "Version sort not available, falling back to numeric extraction"
			sorted_files=("${wav_files[@]}")
		fi
	else
		log_info "Sort command not available, using find order"
		sorted_files=("${wav_files[@]}")
	fi

	# Apply enhanced ordering based on numeric patterns
	validate_and_enhance_ordering()
	{
		local -a temp_files=("$@")
		local -a enhanced_files
		local has_numeric_pattern=false

		for file in "${temp_files[@]}"; do
			local basename_file
			basename_file=$(basename "$file")
			if [[ $basename_file =~ ^[0-9]+.*\.wav$ ]] || [[ $basename_file =~ .*[0-9]+.*\.wav$ ]]; then
				has_numeric_pattern=true
				break
			fi
		done

		if [[ $has_numeric_pattern == true ]]; then
			log_debug "Detected numeric pattern in filenames, enhancing sort"
			mapfile -t enhanced_files < <(
				printf '%s\n' "${temp_files[@]}" |
					sort -t/ -k2 -V
			)
		else
			log_debug "No clear numeric pattern detected, using current order"
			enhanced_files=("${temp_files[@]}")
		fi

		printf '%s\n' "${enhanced_files[@]}"
	}

	# Apply enhanced ordering
	mapfile -t sorted_files < <(validate_and_enhance_ordering "${sorted_files[@]}")

	# Final validation: Log the order for debugging
	log_debug "Final file order:"
	for i in "${!sorted_files[@]}"; do
		log_debug "  $((i + 1)). $(basename "${sorted_files[i]}")"
	done

	# Validate all WAV files, collecting valid ones
	local -a valid_files
	for file in "${sorted_files[@]}"; do
		if validate_wav_file "$file"; then
			valid_files+=("$file")
		else
			log_info "Skipping invalid WAV file: $file"
		fi
	done

	if [[ ${#valid_files[@]} -eq 0 ]]; then
		log_error "No valid WAV files found after validation in: $search_dir"
		return 1
	fi

	log_info "Validated ${#valid_files[@]} WAV files"
	printf '%s\n' "${valid_files[@]}"
}

# Enhanced version of WAV file merging
merge_wav_files_enhanced()
{
	local project_temp_dir="$1"
	shift
	local all_files=("$@")
	local output_file="${all_files[-1]}"
	unset 'all_files[-1]' # Remove output_file from array

	# Sanity check: Ensure all input files are valid WAV files
	local -a valid_files
	for file in "${all_files[@]}"; do
		if [[ $file =~ \.wav$ && -f $file ]]; then
			if validate_wav_file "$file"; then
				valid_files+=("$file")
			else
				log_info "Skipping invalid WAV file: $file"
			fi
		else
			log_info "Skipping non-WAV or missing file: $file"
		fi
	done

	if [[ ${#valid_files[@]} -eq 0 ]]; then
		log_error "No valid WAV files provided for merging in $project_temp_dir"
		return 1
	fi

	log_info "Merging ${#valid_files[@]} WAV files into $output_file..."

	# Log the exact order of files being processed
	log_info "Files will be concatenated in this order:"
	for i in "${!valid_files[@]}"; do
		log_info "  $((i + 1)). $(basename "${valid_files[i]}")"
	done

	# Create a temporary file list for ffmpeg concat
	local concat_list_file="$project_temp_dir/concat_list.txt"
	local temp_resample_dir="$project_temp_dir/resampled"
	local lock_file="$concat_list_file.lock"

	# Use flock for atomic operations
	exec 9>"$lock_file"
	if ! flock -n 9; then
		log_info "Another process is handling merge in $project_temp_dir, waiting..."
		if ! flock -w 60 9; then
			log_error "Failed to acquire lock for $concat_list_file after 60s"
			exec 9>&-
			rm -f "$lock_file"
			return 1
		fi
	fi

	# Build the concat list with optimized resampling
	: >"$concat_list_file"
	log_debug "Resampling WAV files to 48kHz with batch processing..."
	mkdir -p "$temp_resample_dir"

	# Function for resampling a single file
	resample_file()
	{
		local input_file="$1"
		local output_file="$2"
		local attempt=1
		local max_attempts="$MAX_RETRIES"
		local retry_delay="$RETRY_DELAY_SECONDS"

		while [[ $attempt -le $max_attempts ]]; do
			if ffmpeg -i "$input_file" \
				-ar 48000 -ac 1 -c:a pcm_s16le \
				-af "aresample=async=1:first_pts=0" \
				-hide_banner -loglevel error -y \
				"$output_file"; then
				return 0
			fi
			log_info "Resampling failed for $input_file (attempt $attempt/$max_attempts). Retrying after ${retry_delay}s..."
			sleep "$retry_delay"
			retry_delay=$((retry_delay * 2))
			((attempt++))
		done
		log_error "Resampling failed for $input_file after $max_attempts attempts."
		return 1
	}

	# Process files in parallel while maintaining order
	for ((i = 0; i < ${#valid_files[@]}; i++)); do
		local input_file="${valid_files[i]}"
		local resampled_file
		resampled_file="$temp_resample_dir/$(printf "%04d" $i)_$(basename "${valid_files[i]}")"
		local lock_file="$resampled_file.lock"
		exec 8>"$lock_file"
		if ! flock -n 8; then
			log_debug "File $input_file is being processed by another worker"
			exec 8>&-
			continue
		fi
		if needs_resampling "$input_file"; then
			if ! resample_file "$input_file" "$resampled_file"; then
				exec 8>&-
				rm -f "$lock_file"
				return 1
			fi
		else
			# Use original file if no resampling needed
			ln -sf "$input_file" "$resampled_file"
		fi
		exec 8>&-
		rm -f "$lock_file"
		echo "file '$resampled_file'" >>"$concat_list_file"
	done

	# Log the concat list for debugging
	log_debug "Concat list contents:"
	if [[ ${DEBUG:-false} == "true" ]]; then
		while IFS= read -r line; do
			log_debug "  $line"
		done <"$concat_list_file"
	fi

	# Concatenate files with retry logic
	local attempt=1
	local retry_delay="$RETRY_DELAY_SECONDS"
	while [[ $attempt -le $MAX_RETRIES ]]; do
		log_debug "Concatenating files (attempt $attempt/$MAX_RETRIES)..."
		if ffmpeg -f concat -safe 0 -i "$concat_list_file" \
			-c copy -avoid_negative_ts make_zero \
			-fflags +genpts -max_muxing_queue_size 1024 \
			-hide_banner -loglevel error -y \
			"$output_file"; then
			log_info "All WAV files merged successfully into: $output_file"
			exec 9>&-
			rm -f "$lock_file" "$concat_list_file"
			rm -rf "$temp_resample_dir"
			return 0
		fi
		log_info "FFmpeg concat failed (attempt $attempt/$MAX_RETRIES). Retrying after ${retry_delay}s..."
		sleep "$retry_delay"
		retry_delay=$((retry_delay * 2))
		((attempt++))
	done

	log_error "FFmpeg concat failed after $MAX_RETRIES attempts."
	exec 9>&-
	rm -f "$lock_file"
	return 1
}

# Modified process_pdf_project function to use enhanced sorting
process_pdf_project_enhanced()
{
	local pdf_name="$1"
	log_info "Processing project: $pdf_name"

	local project_source_wav_dir="$OUTPUT_DIR/$pdf_name/$WAV_DIR_NAME"
	local project_temp_dir="$TEMP_DIR/$pdf_name"

	# Check if WAV directory exists; skip if missing
	if [[ ! -d $project_source_wav_dir ]]; then
		log_info "WAV directory does not exist: $project_source_wav_dir. Skipping project."
		return 0
	fi

	# Create project-specific temp directory
	mkdir -p "$project_temp_dir" || {
		log_error "Failed to create project temp directory: $project_temp_dir"
		return 1
	}

	log_info "Staging WAV files from '$project_source_wav_dir' to '$project_temp_dir'..."
	if ! rsync -a --quiet "$project_source_wav_dir/" "$project_temp_dir/"; then
		log_error "Failed to stage WAV files for project: $pdf_name"
		return 1
	fi

	log_info "WAV files staged for $pdf_name."

	# Use enhanced file finding and sorting
	local -a all_wav_files
	mapfile -t all_wav_files < <(find_and_sort_wav_files "$project_temp_dir" 2>>"$LOG_FILE")

	if [[ ${#all_wav_files[@]} -eq 0 ]]; then
		log_error "No valid WAV files found in staged directory for $pdf_name: $project_temp_dir"
		return 1
	fi
	log_info "Found ${#all_wav_files[@]} valid WAV files for $pdf_name."

	local final_wav_output="$project_temp_dir/${pdf_name}_final.wav"
	local final_mp3_output="$OUTPUT_DIR/$pdf_name/mp3/${pdf_name}.mp3"

	# Convert WAV to MP3
	convert_to_mp3()
	{
		local input_wav="$1"
		local output_mp3="$2"
		local attempt=1
		local retry_delay="$RETRY_DELAY_SECONDS"

		# Check if input WAV exists
		if [[ ! -f $input_wav ]]; then
			log_error "Input WAV file does not exist: $input_wav"
			return 1
		fi

		while [[ $attempt -le $MAX_RETRIES ]]; do
			if ffmpeg -i "$input_wav" \
				-c:a mp3 -b:a 192k \
				-hide_banner -loglevel error -y \
				"$output_mp3"; then
				return 0
			fi
			log_info "MP3 conversion failed for $input_wav (attempt $attempt/$MAX_RETRIES). Retrying after ${retry_delay}s..."
			sleep "$retry_delay"
			retry_delay=$((retry_delay * 2))
			((attempt++))
		done
		log_error "MP3 conversion failed for $input_wav after $MAX_RETRIES attempts."
		return 1
	}

	mkdir -p "$(dirname "$final_mp3_output")" || {
		log_error "Failed to create MP3 output directory: $(dirname "$final_mp3_output")"
		return 1
	}

	if ! merge_wav_files_enhanced "$project_temp_dir" "${all_wav_files[@]}" "$final_wav_output"; then
		log_error "Failed to merge WAV files for $pdf_name."
		return 1
	fi

	if ! convert_to_mp3 "$final_wav_output" "$final_mp3_output"; then
		log_error "Failed to convert final audio to MP3 for $pdf_name."
		return 1
	fi

	# Clean up project temp directory
	rm -rf "$project_temp_dir"
	log_info "Successfully processed project: $pdf_name"
	return 0
}

# Cleanup temporary files and exit
cleanup_and_exit()
{
	local exit_code=$?
	if [[ $cleanup_called == true ]]; then return; fi
	cleanup_called=true
	log_info "Cleaning up and exiting..."

	if [[ ${#worker_pids[@]} -gt 0 ]]; then
		log_info "Terminating ${#worker_pids[@]} worker processes..."
		for pid in "${worker_pids[@]}"; do
			if [[ $pid -gt 1 ]] && kill -0 "$pid" 2>/dev/null; then
				kill "$pid" 2>/dev/null || true
			fi
		done
		sleep 2
		for pid in "${worker_pids[@]}"; do
			if [[ $pid -gt 1 ]] && kill -0 "$pid" 2>/dev/null; then
				log_info "Force killing worker $pid..."
				kill -9 "$pid" 2>/dev/null || true
			fi
		done
	fi

	if [[ -n ${TEMP_DIR:-} && -d $TEMP_DIR && $TEMP_DIR == "/tmp/combine_chunks"* ]]; then
		log_info "Removing temporary directory: $TEMP_DIR"
		rm -rf "$TEMP_DIR"
	fi

	# Clean up temporary WAV directories
	if [[ -n ${OUTPUT_DIR:-} && -d $OUTPUT_DIR ]]; then
		# Remove temp WAV directories listed in FAILED_LOG.temp_wav_dirs
		if [[ -f "$FAILED_LOG.temp_wav_dirs" ]]; then
			while IFS= read -r temp_dir; do
				if [[ -n $temp_dir && -d $temp_dir && $temp_dir == *"/wav.XXXXXX" ]]; then
					log_info "Removing temporary WAV directory: $temp_dir"
					rm -rf "$temp_dir"
				fi
			done <"$FAILED_LOG.temp_wav_dirs"
			rm -f "$FAILED_LOG.temp_wav_dirs" "$FAILED_LOG.temp_wav_dirs.lock"
		fi
		# Remove any remaining temp WAV directories matching the pattern
		find "$OUTPUT_DIR" -type d -name "wav.XXXXXX" -exec rm -rf {} + 2>/dev/null || true
	fi

	if [[ -n ${LOG_FILE:-} && -f $LOG_FILE ]]; then
		log_info "Log file preserved at: $LOG_FILE"
	fi
	if [[ -n ${FAILED_LOG:-} && -f $FAILED_LOG ]]; then
		rm -f "${FAILED_LOG}.lock"
	fi

	log_info "Cleanup finished. Exiting with code $exit_code."
	exit "$exit_code"
}

# Main entry point
main()
{
	# Prevent re-running if script has already completed
	if [[ $script_completed == true ]]; then
		log_info "Script has already completed successfully. Exiting."
		return 0
	fi

	# Load configuration with validation
	OUTPUT_DIR=$(get_config "paths.output_dir")
	WAV_DIR_NAME=$(get_config "directories.wav")
	TEMP_DIR=$(get_config "processing_dir.combine_chunks")
	WORKERS=$(get_config "settings.workers")
	LOG_DIR=$(get_config "logs_dir.combine_chunks")
	MAX_RETRIES=$(get_config "retry.max_retries")
	RETRY_DELAY_SECONDS=$(get_config "retry.retry_delay_seconds")
	DEBUG=$(get_config "settings.debug" "false")

	# Validate worker count
	local core_count
	core_count=$(nproc) || {
		log_error "Failed to determine number of CPU cores."
		exit 1
	}
	if [[ $WORKERS -gt $core_count ]]; then
		log_info "Reducing worker count from $WORKERS to $core_count (available cores)"
		WORKERS=$core_count
	fi

	# Setup logging
	mkdir -p "$LOG_DIR" || {
		log_error "Failed to create log directory: $LOG_DIR"
		exit 1
	}
	LOG_FILE="$LOG_DIR/log_$(date +'%Y%m%d_%H%M%S').log"
	FAILED_LOG="$LOG_DIR/failed_projects.log"
	touch "$LOG_FILE" "$FAILED_LOG" || {
		log_error "Failed to create log files."
		exit 1
	}
	log_info "Script started. Log file: $LOG_FILE"

	trap 'cleanup_and_exit' EXIT INT TERM
	check_dependencies

	# Process all PDF projects with valid WAV directories
	local -a pdf_dirs
	# Find directories in OUTPUT_DIR where the WAV subdirectory exists
	mapfile -t pdf_dirs < <(find "$OUTPUT_DIR" -maxdepth 1 -type d -not -path "$OUTPUT_DIR" -exec test -d {}/"$WAV_DIR_NAME" \; -exec basename {} \; | sort)
	if [[ ${#pdf_dirs[@]} -eq 0 ]]; then
		log_info "No PDF projects with valid WAV directories found in $OUTPUT_DIR"
		script_completed=true
		return 0
	fi
	log_info "Found ${#pdf_dirs[@]} PDF projects with valid WAV directories"

	local -a failed_projects
	for pdf_name in "${pdf_dirs[@]}"; do
		if ! process_pdf_project_enhanced "$pdf_name"; then
			echo "$pdf_name" >>"$FAILED_LOG"
		fi
	done

	# Retry failed projects
	local retry_attempt=1
	local retry_delay="$RETRY_DELAY_SECONDS"
	while [[ $retry_attempt -le $MAX_RETRIES && -s $FAILED_LOG ]]; do
		mapfile -t failed_projects <"$FAILED_LOG"
		: >"$FAILED_LOG"
		log_info "Retrying ${#failed_projects[@]} failed projects (attempt $retry_attempt/$MAX_RETRIES) after ${retry_delay}s delay..."
		sleep "$retry_delay"
		for pdf_name in "${failed_projects[@]}"; do
			if ! process_pdf_project_enhanced "$pdf_name"; then
				echo "$pdf_name" >>"$FAILED_LOG"
			fi
		done
		retry_delay=$((retry_delay * 2))
		((retry_attempt++))
	done

	if [[ -s $FAILED_LOG ]]; then
		local failed_count
		failed_count=$(wc -l <"$FAILED_LOG")
		log_error "$failed_count projects failed after all retries. See '$FAILED_LOG' for details."
		return 1
	fi

	log_info "All projects processed successfully."
	script_completed=true
	return 0
}

# Entry point for the script
main "$@"
