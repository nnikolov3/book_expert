#!/usr/bin/env bash
# combine.sh
# Design: Niko Nikolov
# Code: Various LLMs

set -euo pipefail

# --- Configuration ---
# Path to project configuration file
declare CONFIG_FILE="$PWD/project.toml"

# --- Global Variables ---
# Initialize all variables with defaults
declare OUTPUT_DIR=""
declare INPUT_DIR=""
declare PROCESSING_DIR=""
declare LOG_DIR=""
declare LOG_FILE=""
declare FAILED_LOG=""

declare -a SORTED_WAVS=()

# Get configuration value from TOML file
get_config()
{
	local key="$1"
	local default_value="${2:-}"
	local value=""

	value=$(yq -r ".${key} // \"\"" "$CONFIG_FILE")
	local yq_exit_code=$?

	if [[ $yq_exit_code -ne 0 ]]; then
		if [[ -n $default_value ]]; then
			echo "$default_value"
			return 0
		fi
		log_error "Failed to read configuration key '$key' from $CONFIG_FILE"
		exit 1
	fi

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

# Enhanced logging functions with timestamp, stdout output, and file output
log_info()
{
	local timestamp=""
	timestamp=$(date '+%Y-%m-%d %H:%M:%S')
	local message="[$timestamp] INFO: $*"
	echo "$message"
	echo "$message" >>"$LOG_FILE"
	print_line
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
	echo "$message" >&2
	echo "$message" >>"$LOG_FILE"
	print_line
	return 1
}

# Print line separator
print_line()
{
	echo "========================================================================================"
}

# Check dependencies
check_dependencies()
{
	local deps=("ffmpeg" "rsync" "sort" "yq" "nproc")
	local dep=""

	for dep in "${deps[@]}"; do
		local cmd_check=""
		cmd_check=$(command -v "$dep")
		if [[ -z $cmd_check ]]; then
			log_error "'$dep' is not installed."
			exit 1
		fi
	done
	log_success "All dependencies are available."
}

# Validate WAV file integrity
validate_wav_file()
{
	local file="$1"

	if [[ ! -f $file ]]; then
		log_error "File does not exist: $file"
		return 1
	fi

	local ffmpeg_output=""
	ffmpeg_output=$(ffmpeg -i "$file" -f null - 2>&1)
	local ffmpeg_exit_code=$?

	if [[ $ffmpeg_exit_code -ne 0 ]]; then
		log_error "Invalid WAV file (ffmpeg failed to process): $file"
		return 1
	fi
	return 0
}

# File ordering function for WAV concatenation
find_and_sort_wav_files()
{
	local search_dir="$1"
	SORTED_WAVS=()

	log_info "Searching for WAV files in: $search_dir"

	# Find all WAV files, ensuring output is clean
	local find_output=""
	find_output=$(find "$search_dir" -maxdepth 1 -name "*.wav" -type f | sort -n)

	if [[ -z $find_output ]]; then
		log_error "No WAV files found in directory: $search_dir"
		return 1
	fi

	# Read the sorted output into array
	mapfile -t SORTED_WAVS <<<"$find_output"

	log_info "Found ${#SORTED_WAVS[@]} WAV files to sort"
}

# Check if resampling can be skipped
check_resampled_files()
{
	local wav_dir="$1"
	local resampled_dir="$2"

	if [[ ! -d $resampled_dir ]]; then
		return 1
	fi

	local wav_count=""
	wav_count=$(find "$wav_dir" -maxdepth 1 -name "*.wav" -type f | wc -l)
	local resampled_count=""
	resampled_count=$(find "$resampled_dir" -maxdepth 1 -name "*.wav" -type f | wc -l)

	if [[ $wav_count -eq $resampled_count ]]; then
		return 0
	fi

	return 1
}

merge_wav_files()
{
	local project_temp_dir="$1"
	local output_file="$2"
	local pdf_name="$3"

	local concat_list_file="$project_temp_dir/concat_list.txt"
	local temp_resample_dir="$project_temp_dir/resampled"
	local persistent_resample_dir="$OUTPUT_DIR/$pdf_name/resampled"

	# Check if we can skip resampling
	local original_wav_dir="$OUTPUT_DIR/$pdf_name/wav"
	if check_resampled_files "$original_wav_dir" "$persistent_resample_dir"; then
		log_info "Resampled files already exist and match WAV count, skipping resampling"
		temp_resample_dir="$persistent_resample_dir"
	else
		log_info "Resampling required"
		mkdir -p "$temp_resample_dir"
		mkdir -p "$persistent_resample_dir"

		# Inline resampling function (no retries)
		resample_file()
		{
			local input_file="$1"
			local output_file="$2"
			echo "INFO: RESAMPLING file $input_file"
			local ffmpeg_output=""
			ffmpeg_output=$(ffmpeg -i "$input_file" \
				-ar 48000 -ac 1 -c:a pcm_s32le \
				-af "aresample=async=1:first_pts=0" \
				-rf64 auto \
				-hide_banner -loglevel error -y \
				"$output_file")
			local ffmpeg_exit_code=$?

			if [[ $ffmpeg_exit_code -ne 0 ]]; then
				log_error "Failed to resample file: $input_file"
				return 1
			fi
			return 0
		}

		# Resample each file
		local i=0
		for ((i = 0; i < ${#SORTED_WAVS[@]}; i++)); do
			local input_file="${SORTED_WAVS[i]}"
			local resampled_file=""
			resampled_file="$temp_resample_dir/$(basename "${SORTED_WAVS[i]}")"
			local persistent_resampled_file=""
			persistent_resampled_file="$persistent_resample_dir/$(basename "${SORTED_WAVS[i]}")"

			resample_file "$input_file" "$resampled_file"
			rsync -a "$resampled_file" "$persistent_resampled_file"
		done
		log_info "Resampling complete"
	fi

	# Generate concat list
	local find_resampled_output=""
	find_resampled_output=$(find "$temp_resample_dir" -maxdepth 1 -type f -iname "*.wav" | sort -n)

	if [[ -z $find_resampled_output ]]; then
		log_error "No resampled files found in $temp_resample_dir"
		return 1
	fi

	# Create concat list file
	while IFS= read -r wav_file; do
		echo "file '$wav_file'" >>"$concat_list_file"
	done <<<"$find_resampled_output"

	echo "INFO: CONCAT LIST $concat_list_file"

	# Merge with FFmpeg
	#
	ffmpeg -f concat -safe 0 -i "$concat_list_file" \
		-c copy -avoid_negative_ts make_zero \
		-fflags +genpts -max_muxing_queue_size 1024 \
		-rf64 auto \
		-hide_banner -loglevel error -y \
		"$output_file"
	local merge_exit_code=$?

	if [[ $merge_exit_code -ne 0 ]]; then
		log_error "Failed to merge WAV files"
		return 1
	fi

	log_success "All WAV files merged successfully into: $output_file"
}

convert_to_mp3()
{
	local input_wav="$1"
	local output_mp3="$2"
	local attempt=1

	# Check if WAV exists
	if [[ ! -f $input_wav ]]; then
		log_error "Input WAV file does not exist: $input_wav"
		return 1
	fi

	local ffmpeg_output=""
	ffmpeg_output=$(ffmpeg -i "$input_wav" \
		-c:a libmp3lame -q:a 0 \
		-hide_banner -loglevel error -y \
		"$output_mp3" 2>&1)
	local ffmpeg_exit_code=$?

	if [[ $ffmpeg_exit_code -eq 0 ]]; then
		log_success "MP3 conversion completed successfully"
		return 0
	fi

	log_error "MP3 conversion failed for $input_wav (attempt $attempt): $ffmpeg_output"
	return 1
}

# Process PDF project
process_pdf_project()
{
	local pdf_name="$1"
	local project_temp_dir="$2"
	log_info "Processing project: $pdf_name"

	local project_source_wav_dir=""
	project_source_wav_dir="$OUTPUT_DIR/$pdf_name/wav"

	if [[ -d $project_source_wav_dir ]]; then
		log_info "Staging WAV files from '$project_source_wav_dir' to '$project_temp_dir'..."

		local rsync_output=""
		rsync_output=$(rsync -a "$project_source_wav_dir/" "$project_temp_dir/" 2>&1)
		local rsync_exit_code=$?

		if [[ $rsync_exit_code -ne 0 ]]; then
			log_error "Failed to stage WAV files: $rsync_output"
			return 1
		fi

		log_success "WAV files staged for $pdf_name."

		# Reset
		SORTED_WAVS=()
		find_and_sort_wav_files "$project_temp_dir"

		if [[ ${#SORTED_WAVS[@]} -eq 0 ]]; then
			log_error "No valid WAV files found in staged directory for $pdf_name: $project_temp_dir"
			return 1
		fi
		log_info "Found ${#SORTED_WAVS[@]} valid WAV files for $pdf_name."

		local final_wav_output="$project_temp_dir/${pdf_name}_final.wav"
		local final_mp3_output="$OUTPUT_DIR/$pdf_name/mp3/${pdf_name}.mp3"
		local final_dir_output="$OUTPUT_DIR/$pdf_name/mp3"

		local mkdir_output=""
		mkdir_output=$(mkdir -p "$(dirname "$final_dir_output")")
		local mkdir_exit_code=$?

		if [[ $mkdir_exit_code -ne 0 ]]; then
			log_error "Failed to create MP3 output directory: $(dirname "$final_mp3_output") - $mkdir_output"
			return 1
		fi

		merge_wav_files "$project_temp_dir" "$final_wav_output" "$pdf_name"

		convert_to_mp3 "$final_wav_output" "$final_mp3_output"

		log_success "Successfully processed project: $pdf_name"
		return 0
	fi

	log_info "SKIPPING, no WAV folder for project: $pdf_name"
	return 1
}

# Cleanup temporary files and exit
cleanup_and_exit()
{
	if [[ -n $PROCESSING_DIR && -d $PROCESSING_DIR ]]; then
		rm -rf "$PROCESSING_DIR"
	fi
}

# Main entry point
main()
{
	# Load configuration with validation
	OUTPUT_DIR=$(get_config "paths.output_dir")
	INPUT_DIR=$(get_config "paths.output_dir")
	PROCESSING_DIR=$(get_config "processing_dir.combine_chunks")
	LOG_DIR=$(get_config "logs_dir.combine_chunks")

	# Setup logging
	local mkdir_log_output=""
	mkdir_log_output=$(mkdir -p "$LOG_DIR" 2>&1)
	local mkdir_log_exit_code=$?

	if [[ $mkdir_log_exit_code -ne 0 ]]; then
		echo "ERROR: Failed to create log directory: $LOG_DIR - $mkdir_log_output" >&2
		exit 1
	fi

	LOG_FILE="$LOG_DIR/log_$(date +'%Y%m%d_%H%M%S').log"
	FAILED_LOG="$LOG_DIR/failed_projects.log"

	local touch_output=""
	touch_output=$(touch "$LOG_FILE" "$FAILED_LOG" 2>&1)
	local touch_exit_code=$?

	if [[ $touch_exit_code -ne 0 ]]; then
		echo "ERROR: Failed to create log files: $touch_output" >&2
		exit 1
	fi

	log_info "Script started. Log file: $LOG_FILE"

	trap 'cleanup_and_exit' EXIT INT TERM
	check_dependencies

	# Process all PDF projects with valid WAV directories
	local -a pdf_dirs=()

	# Find directories in INPUT_DIR where the WAV subdirectory exists
	local find_pdf_output=""
	find_pdf_output=$(find "$INPUT_DIR" -type f -name "*.pdf" -exec basename {} .pdf \;)

	if [[ -z $find_pdf_output ]]; then
		log_warn "No PDF projects found in $INPUT_DIR"
		exit 0
	fi

	mapfile -t pdf_dirs <<<"$find_pdf_output"

	log_info "Found ${#pdf_dirs[@]} PDF projects"

	local pdf_name=""
	for pdf_name in "${pdf_dirs[@]}"; do
		SORTED_WAVS=()
		echo "INFO: CLEANED OLD PROCESSING_DIR"
		rm -rf "$PROCESSING_DIR"
		echo "INFO: Creating new PROCESSING_DIR"
		local processing_dir="$PROCESSING_DIR/$pdf_name/wav"

		local mkdir_proc_output=""
		mkdir_proc_output=$(mkdir -p "$processing_dir" 2>&1)
		local mkdir_proc_exit_code=$?

		if [[ $mkdir_proc_exit_code -ne 0 ]]; then
			log_error "Failed to create processing directory: $processing_dir - $mkdir_proc_output"
			echo "$pdf_name" >>"$FAILED_LOG"
			continue
		fi

		process_pdf_project "$pdf_name" "$processing_dir"
		local process_exit_code=$?

		if [[ $process_exit_code -ne 0 ]]; then
			echo "$pdf_name" >>"$FAILED_LOG"
		fi
	done

	log_success "All projects processed successfully."

	echo "SUCCESS!"
	print_line
	return 0
}

# Entry point for the script
main "$@"
