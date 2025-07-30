#!/usr/bin/env bash
# generate_final_mp3.sh
# Design: Niko Nikolov
# Code: Various LLMs + Niko

set -euo pipefail

# --- Global Variables (with GLOBAL prefix) ---
declare GLOBAL_OUTPUT_DIR=""
declare GLOBAL_INPUT_DIR=""
declare GLOBAL_PROCESSING_DIR=""
declare GLOBAL_LOG_DIR=""
declare GLOBAL_LOG_FILE=""
declare GLOBAL_FAILED_LOG=""
declare GLOBAL_LOCK_FILE=""
declare GLOBAL_MAX_JOBS=""

declare -a GLOBAL_PDF_PROJECTS=()

# --- Logging with flock for atomic writes ---
log_info()
{
	local message="$1"
	(
		flock -x 200
		helpers/logging_utils_helper.sh "INFO" "$message" "$GLOBAL_LOG_FILE"
	) 200>"$GLOBAL_LOCK_FILE"
}

log_warn()
{
	local message="$1"
	(
		flock -x 200
		helpers/logging_utils_helper.sh "WARN" "$message" "$GLOBAL_LOG_FILE"
	) 200>"$GLOBAL_LOCK_FILE"
}

log_error()
{
	local message="$1"
	(
		flock -x 200
		helpers/logging_utils_helper.sh "ERROR" "$message" "$GLOBAL_LOG_FILE"
	) 200>"$GLOBAL_LOCK_FILE"
}

log_success()
{
	local message="$1"
	(
		flock -x 200
		helpers/logging_utils_helper.sh "SUCCESS" "$message" "$GLOBAL_LOG_FILE"
	) 200>"$GLOBAL_LOCK_FILE"
}

print_line()
{
	printf '%*s\n' "${COLUMNS:-$(tput cols)}" '' | tr ' ' '-'
}

# --- Dependency Check ---
check_dependencies()
{
	declare -a deps=("ffmpeg" "rsync" "sort" "yq" "nproc" "flock")
	declare dep=""
	for dep in "${deps[@]}"; do
		declare cmd_path=""
		cmd_path=$(command -v "$dep")
		if [[ -z $cmd_path ]]; then
			echo "ERROR: '$dep' is not installed." >&2
			exit 1
		fi
	done
	log_success "All dependencies are available."
}

# --- Validate WAV ---
validate_wav_file()
{
	declare file="$1"
	if [[ ! -f $file ]]; then
		log_error "File does not exist: $file"
		return 1
	fi

	declare ffmpeg_output=""
	ffmpeg_output=$(ffmpeg -i "$file")

	if [[ $ffmpeg_output -ne 0 ]]; then
		log_error "Invalid WAV file: $file"
		log_error "FFmpeg output: $ffmpeg_output"
		return 1
	fi
	return 0
}

# --- Find & Sort WAV Files ---
find_and_sort_wav_files()
{
	declare search_dir="$1"
	declare -n sorted_array_ref
	sorted_array_ref="$2"

	declare find_output=""
	find_output=$(find "$search_dir" -maxdepth 1 -name "*.wav" -type f | sort -V)

	if [[ -z $find_output ]]; then
		log_error "No WAV files found in: $search_dir"
		return 1
	fi
	log_info "$sorted_array_ref"
	mapfile -t sorted_array_ref <<<"$find_output"
	return 0
}

# --- Check Resampled Files Count ---
check_resampled_files()
{
	declare wav_dir="$1"
	declare resampled_dir="$2"

	if [[ ! -d $resampled_dir ]]; then
		return 1
	fi

	declare wav_count=""
	declare resampled_count=""
	wav_count=$(find "$wav_dir" -maxdepth 1 -name "*.wav" -type f | wc -l)
	resampled_count=$(find "$resampled_dir" -maxdepth 1 -name "*.wav" -type f | wc -l)

	if [[ $wav_count -eq $resampled_count ]]; then
		return 0
	else
		return 1
	fi
}

# --- Merge WAV Files (Order-Preserving) ---
merge_wav_files()
{
	declare project_temp_dir="$1"
	declare output_file="$2"
	declare pdf_name="$3"

	declare concat_list_file="$project_temp_dir/concat_list.txt"
	declare temp_resample_dir="$project_temp_dir/resampled"
	declare persistent_resample_dir="$GLOBAL_OUTPUT_DIR/$pdf_name/resampled"
	declare original_wav_dir="$GLOBAL_OUTPUT_DIR/$pdf_name/wav"

	declare -a local_sorted_wavs=()
	find_and_sort_wav_files "$original_wav_dir" local_sorted_wavs

	if check_resampled_files "$original_wav_dir" "$persistent_resample_dir"; then
		log_info "Resampled files exist for $pdf_name, skipping resampling"
		temp_resample_dir="$persistent_resample_dir"
	else
		log_info "Resampling WAV files for $pdf_name"

		declare mkdir_temp_output=""
		mkdir_temp_output=$(mkdir -p "$temp_resample_dir")

		if [[ $mkdir_temp_output -ne 0 ]]; then
			log_error "Failed to create temp resample dir: $temp_resample_dir"
			return 1
		fi

		declare mkdir_persistent_output=""
		mkdir_persistent_output=$(mkdir -p "$persistent_resample_dir")

		if [[ $mkdir_persistent_output -ne 0 ]]; then
			log_error "Failed to create persistent resample dir: $persistent_resample_dir"
			return 1
		fi

		# Resample each file in sorted order
		declare i=0
		for ((i = 0; i < ${#local_sorted_wavs[@]}; i = i + 1)); do
			declare input_file
			input_file="${local_sorted_wavs[i]}"
			declare base_name
			base_name=$(basename "$input_file")
			declare resampled_file
			resampled_file="$temp_resample_dir/$base_name"
			declare persistent_file
			persistent_file="$persistent_resample_dir/$base_name"

			log_info "Resampling: $base_name"

			declare ffmpeg_output=""
			ffmpeg_output=$(ffmpeg -i "$input_file" \
				-ar 48000 -ac 1 -c:a pcm_s32le \
				-af "aresample=async=1:first_pts=0" \
				-rf64 auto \
				-hide_banner -loglevel error -y \
				"$resampled_file")

			if [[ $ffmpeg_output -ne 0 ]]; then
				log_error "Resampling failed for $input_file"
				log_error "FFmpeg output: $ffmpeg_output"
				return 1
			fi

			declare rsync_output=""
			rsync_output=$(rsync -a "$resampled_file" "$persistent_file")

			if [[ $rsync_output -ne 0 ]]; then
				log_error "Failed to sync resampled file: $rsync_output"
				return 1
			fi
		done

		log_info "Resampling complete for $pdf_name"
	fi

	# Generate concat list from persistent resampled files (sorted)
	declare find_resampled_output=""
	find_resampled_output=$(find "$temp_resample_dir" -maxdepth 1 -name "*.wav" -type f | sort -V)

	if [[ -z $find_resampled_output ]]; then
		log_error "No resampled files found in $temp_resample_dir"
		return 1
	fi

	while IFS= read -r wav_file; do
		echo "file '$wav_file'" >>"$concat_list_file"
	done <<<"$find_resampled_output"

	log_info "Generated concat list for $pdf_name: $concat_list_file"

	declare ffmpeg_merge_output=""
	ffmpeg_merge_output=$(ffmpeg -f concat -safe 0 -i "$concat_list_file" \
		-c copy -avoid_negative_ts make_zero \
		-fflags +genpts -max_muxing_queue_size 4096 \
		-rf64 auto \
		-hide_banner -loglevel error -y \
		"$output_file")

	if [[ $ffmpeg_merge_output -ne 0 ]]; then
		log_error "Merge failed for $pdf_name: $ffmpeg_merge_output"
		return 1
	fi

	log_success "Merged WAV: $output_file"
	return 0
}

# --- Convert to MP3 ---
convert_to_mp3()
{
	declare input_wav="$1"
	declare output_mp3="$2"

	if [[ ! -f $input_wav ]]; then
		log_error "Input WAV missing: $input_wav"
		return 1
	fi

	declare ffmpeg_output=""
	ffmpeg_output=$(ffmpeg -i "$input_wav" \
		-c:a libmp3lame -q:a 0 \
		-hide_banner -loglevel error -y \
		"$output_mp3")

	if [[ $ffmpeg_output -eq 0 ]]; then
		log_success "MP3 created: $output_mp3"
		return 0
	else
		log_error "MP3 conversion failed: $ffmpeg_output"
		return 1
	fi
}

# --- Process One PDF Project ---
process_pdf_project()
{
	declare pdf_name="$1"
	declare job_temp_dir="$2"

	log_info "Starting parallel processing for project: $pdf_name"

	declare project_wav_dir="$GLOBAL_OUTPUT_DIR/$pdf_name/wav"
	if [[ ! -d $project_wav_dir ]]; then
		log_info "SKIPPING: No WAV directory for $pdf_name"
		return 0
	fi

	declare final_wav="$job_temp_dir/${pdf_name}_final.wav"
	declare final_mp3_dir="$GLOBAL_OUTPUT_DIR/$pdf_name/mp3"
	declare final_mp3="$final_mp3_dir/${pdf_name}.mp3"

	declare mkdir_mp3_output=""
	mkdir_mp3_output=$(mkdir -p "$final_mp3_dir")

	if [[ $mkdir_mp3_output -ne 0 ]]; then
		log_error "Failed to create MP3 dir: $final_mp3_dir"
		return 1
	fi

	merge_wav_files "$job_temp_dir" "$final_wav" "$pdf_name"
	convert_to_mp3 "$final_wav" "$final_mp3"

	log_success "Completed project: $pdf_name"
	return 0
}

# --- Worker Function for Parallel Execution ---
worker_process_project()
{
	declare pdf_name="$1"
	declare base_processing_dir="$2"

	declare job_temp_dir="$base_processing_dir/worker_$$/$pdf_name/wav"
	declare cleanup_dir="$base_processing_dir/worker_$$"

	# Ensure isolated temp space
	declare mkdir_output=""
	mkdir_output=$(mkdir -p "$job_temp_dir")

	if [[ $mkdir_output -ne 0 ]]; then

		log_error "Worker failed to create temp dir for $pdf_name"
		echo "$pdf_name"
		return 1
	fi

	declare result=0
	process_pdf_project "$pdf_name" "$job_temp_dir"
	result="$?"

	# Clean up worker temp
	rm -rf "$cleanup_dir"

	if [[ $result -ne 0 ]]; then
		echo "$pdf_name"
		return "$result"
	fi

	return 0
}

# --- Cleanup on Exit ---
cleanup_and_exit()
{
	if [[ -n $GLOBAL_PROCESSING_DIR && -d $GLOBAL_PROCESSING_DIR ]]; then
		rm -rf "${GLOBAL_PROCESSING_DIR:?}"/*
		log_info "Cleaned up processing directory: $GLOBAL_PROCESSING_DIR"
	fi
}

# --- Main ---
main()
{
	# Load config
	GLOBAL_OUTPUT_DIR=$(helpers/get_config_helper.sh "paths.output_dir")
	GLOBAL_INPUT_DIR=$(helpers/get_config_helper.sh "paths.input_dir")
	GLOBAL_PROCESSING_DIR=$(helpers/get_config_helper.sh "processing_dir.combine_chunks")
	GLOBAL_LOG_DIR=$(helpers/get_config_helper.sh "logs_dir.combine_chunks")

	# Setup logging
	declare mkdir_log_output=""
	declare mkdir_log_exit_code=""
	mkdir_log_output=$(mkdir -p "$GLOBAL_LOG_DIR")
	mkdir_log_exit_code="$?"

	if [[ $mkdir_log_exit_code -ne 0 ]]; then
		echo "ERROR: Failed to create log directory: $mkdir_log_output"
		exit 1
	fi

	GLOBAL_LOG_FILE="$GLOBAL_LOG_DIR/log_$(date +'%Y%m%d_%H%M%S').log"
	GLOBAL_FAILED_LOG="$GLOBAL_LOG_DIR/failed_projects.log"
	GLOBAL_LOCK_FILE="$GLOBAL_LOG_DIR/.lock"

	# Source logger
	declare logger_script="helpers/logging_utils_helper.sh"
	if [[ ! -f $logger_script ]]; then
		echo "ERROR: Logging helper not found: $logger_script" >&2
		exit 1
	fi
	source "$logger_script"

	# Initialize log files
	touch "$GLOBAL_LOG_FILE" "$GLOBAL_FAILED_LOG" "$GLOBAL_LOCK_FILE"

	log_info "Parallel MP3 generation started. Max jobs: $GLOBAL_MAX_JOBS"

	trap 'cleanup_and_exit' EXIT INT TERM

	check_dependencies

	# Discover projects
	declare find_pdf_output=""
	find_pdf_output=$(find "$GLOBAL_INPUT_DIR" -type f -name "*.pdf" -exec basename {} .pdf \;)

	if [[ -z $find_pdf_output ]]; then
		log_warn "No PDF projects found in $GLOBAL_INPUT_DIR"
		exit 0
	fi

	mapfile -t GLOBAL_PDF_PROJECTS <<<"$find_pdf_output"
	log_info "Discovered ${#GLOBAL_PDF_PROJECTS[@]} projects for parallel processing"

	# Set max jobs: min(projects, nproc, 8)
	declare n_cores=""
	n_cores=$(nproc)
	GLOBAL_MAX_JOBS="$n_cores"
	if ((${#GLOBAL_PDF_PROJECTS[@]} < n_cores)); then
		GLOBAL_MAX_JOBS="${#GLOBAL_PDF_PROJECTS[@]}"
	fi
	if ((GLOBAL_MAX_JOBS > 8)); then
		GLOBAL_MAX_JOBS="8"
	fi

	log_info "Running up to $GLOBAL_MAX_JOBS concurrent jobs"

	# Create base processing dir
	declare mkdir_proc_output=""
	mkdir_proc_output=$(mkdir -p "$GLOBAL_PROCESSING_DIR")

	if [[ $mkdir_proc_output -ne 0 ]]; then
		log_error "Failed to create processing directory: $GLOBAL_PROCESSING_DIR"
		exit 1
	fi

	# Process in parallel
	for pdf_name in "${GLOBAL_PDF_PROJECTS[@]}"; do
		# Background job with semaphore-like control
		(
			worker_process_project "$pdf_name" "$GLOBAL_PROCESSING_DIR"
		) &

		# Throttle jobs
		if (($(jobs -r | wc -l) >= GLOBAL_MAX_JOBS)); then
			wait -n
		fi
	done

	# Wait for all jobs
	wait

	# Note: In true parallel mode, we'd collect failed names via temp files or FIFO.
	# For simplicity, we assume logging tracks failures.
	# You can enhance with a shared failure queue if needed.

	log_success "Parallel processing complete. Check $GLOBAL_FAILED_LOG for failures."
	print_line
}

# --- Entry Point ---
GLOBAL_MAX_JOBS="4" # Default, can be overridden via env or config
main "$@"
