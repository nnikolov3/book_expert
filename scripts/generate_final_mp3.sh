#!/usr/bin/env bash
# generate_final_mp3.sh
# Design: Niko Nikolov
# Code: Various LLMs

set -euo pipefail

# --- Configuration ---
# Path to project configuration file
declare -r CONFIG_FILE="$PWD/../project.toml"
export CONFIG_FILE

# --- Global Variables ---
# Initialize all variables with defaults
declare OUTPUT_DIR=""
declare INPUT_DIR=""
declare PROCESSING_DIR=""
declare LOG_DIR=""
declare LOG_FILE=""
declare FAILED_LOG=""

declare -a SORTED_WAVS=()

# Check if all required dependencies are available
check_dependencies()
{
	declare -a deps=("ffmpeg" "rsync" "sort" "yq" "nproc")
	declare dep=""

	for dep in "${deps[@]}"; do
		declare cmd_check=""
		cmd_check=$(command -v "$dep")
		if [[ -z $cmd_check ]]; then
			log_error "'$dep' is not installed."
			exit 1
		fi
	done
	log_success "All dependencies are available."
}

# Validate WAV file integrity using ffmpeg
validate_wav_file()
{
	declare file="$1"

	if [[ ! -f $file ]]; then
		log_error "File does not exist: $file"
		return 1
	fi

	declare ffmpeg_output=""
	declare ffmpeg_exit_code=""
	ffmpeg_output=$(ffmpeg -i "$file" -f null - 2>&1)
	ffmpeg_exit_code="$?"

	if [[ $ffmpeg_exit_code -ne 0 ]]; then
		log_error "Invalid WAV file (ffmpeg failed to process): $file"
		log_error "FFmpeg output: $ffmpeg_output"
		return 1
	fi
	return 0
}

# Find and sort WAV files for concatenation
find_and_sort_wav_files()
{
	declare search_dir="$1"
	SORTED_WAVS=()

	log_info "Searching for WAV files in: $search_dir"

	# Find all WAV files, ensuring output is clean
	declare find_output=""
	find_output=$(find "$search_dir" -maxdepth 1 -name "*.wav" -type f | sort -n)

	if [[ -z $find_output ]]; then
		log_error "No WAV files found in directory: $search_dir"
		return 1
	fi

	# Read the sorted output into array
	mapfile -t SORTED_WAVS <<<"$find_output"

	log_info "Found ${#SORTED_WAVS[@]} WAV files to sort"
}

# Check if resampling can be skipped by comparing file counts
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
	fi

	return 1
}

# Merge WAV files into a single output file
merge_wav_files()
{
	declare project_temp_dir="$1"
	declare output_file="$2"
	declare pdf_name="$3"

	declare concat_list_file="$project_temp_dir/concat_list.txt"
	declare temp_resample_dir="$project_temp_dir/resampled"
	declare persistent_resample_dir="$OUTPUT_DIR/$pdf_name/resampled"

	# Check if we can skip resampling
	declare original_wav_dir="$OUTPUT_DIR/$pdf_name/wav"
	if check_resampled_files "$original_wav_dir" "$persistent_resample_dir"; then
		log_info "Resampled files already exist and match WAV count, skipping resampling"
		temp_resample_dir="$persistent_resample_dir"
	else
		log_info "Resampling required"
		declare mkdir_temp_output=""
		declare mkdir_temp_exit_code=""
		declare mkdir_persistent_output=""
		declare mkdir_persistent_exit_code=""

		mkdir_temp_output=$(mkdir -p "$temp_resample_dir")
		mkdir_temp_exit_code="$?"
		mkdir_persistent_output=$(mkdir -p "$persistent_resample_dir")
		mkdir_persistent_exit_code="$?"

		if [[ $mkdir_temp_exit_code -ne 0 ]]; then
			log_error "Failed to create temp resample directory: $mkdir_temp_output"
			return 1
		fi

		if [[ $mkdir_persistent_exit_code -ne 0 ]]; then
			log_error "Failed to create persistent resample directory: $mkdir_persistent_output"
			return 1
		fi

		# Inline resampling function
		resample_file()
		{
			declare input_file="$1"
			declare output_file="$2"
			declare ffmpeg_output=""
			declare ffmpeg_exit_code=""

			echo "INFO: RESAMPLING file $input_file"
			ffmpeg_output=$(ffmpeg -i "$input_file" \
				-ar 48000 -ac 1 -c:a pcm_s32le \
				-af "aresample=async=1:first_pts=0" \
				-rf64 auto \
				-hide_banner -loglevel error -y \
				"$output_file" 2>&1)
			ffmpeg_exit_code="$?"

			if [[ $ffmpeg_exit_code -ne 0 ]]; then
				log_error "Failed to resample file: $input_file"
				log_error "FFmpeg output: $ffmpeg_output"
				return 1
			fi
			return 0
		}

		# Resample each file
		declare i=0
		for ((i = 0; i < ${#SORTED_WAVS[@]}; i = i + 1)); do
			declare input_file="${SORTED_WAVS[i]}"
			declare resampled_file=""
			declare persistent_resampled_file=""
			declare rsync_output=""
			declare rsync_exit_code=""

			resampled_file="$temp_resample_dir/$(basename "${SORTED_WAVS[i]}")"
			persistent_resampled_file="$persistent_resample_dir/$(basename "${SORTED_WAVS[i]}")"

			resample_file "$input_file" "$resampled_file"
			rsync_output=$(rsync -a "$resampled_file" "$persistent_resampled_file")
			rsync_exit_code="$?"

			if [[ $rsync_exit_code -ne 0 ]]; then
				log_error "Failed to sync resampled file: $rsync_output"
				return 1
			fi
		done
		log_info "Resampling complete"
	fi

	# Generate concat list
	declare find_resampled_output=""
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
	declare ffmpeg_merge_output=""
	declare merge_exit_code=""
	ffmpeg_merge_output=$(ffmpeg -f concat -safe 0 -i "$concat_list_file" \
		-c copy -avoid_negative_ts make_zero \
		-fflags +genpts -max_muxing_queue_size 1024 \
		-rf64 auto \
		-hide_banner -loglevel error -y \
		"$output_file" 2>&1)
	merge_exit_code="$?"

	if [[ $merge_exit_code -ne 0 ]]; then
		log_error "Failed to merge WAV files: $ffmpeg_merge_output"
		return 1
	fi

	log_success "All WAV files merged successfully into: $output_file"
}

# Convert WAV file to MP3 format
convert_to_mp3()
{
	declare input_wav="$1"
	declare output_mp3="$2"

	# Check if WAV exists
	if [[ ! -f $input_wav ]]; then
		log_error "Input WAV file does not exist: $input_wav"
		return 1
	fi

	declare ffmpeg_output=""
	declare ffmpeg_exit_code=""
	ffmpeg_output=$(ffmpeg -i "$input_wav" \
		-c:a libmp3lame -q:a 0 \
		-hide_banner -loglevel error -y \
		"$output_mp3" 2>&1)
	ffmpeg_exit_code="$?"

	if [[ $ffmpeg_exit_code -eq 0 ]]; then
		log_success "MP3 conversion completed successfully"
		return 0
	fi

	log_error "MP3 conversion failed for $input_wav: $ffmpeg_output"
	return 1
}

# Process individual PDF project
process_pdf_project()
{
	declare pdf_name="$1"
	declare project_temp_dir="$2"

	log_info "Processing project: $pdf_name"

	declare project_source_wav_dir="$OUTPUT_DIR/$pdf_name/wav"

	if [[ -d $project_source_wav_dir ]]; then
		log_info "Staging WAV files from '$project_source_wav_dir' to '$project_temp_dir'..."

		declare rsync_output=""
		declare rsync_exit_code=""
		rsync_output=$(rsync -a "$project_source_wav_dir/" "$project_temp_dir/")
		rsync_exit_code="$?"

		if [[ $rsync_exit_code -ne 0 ]]; then
			log_error "Failed to stage WAV files: $rsync_output"
			return 1
		fi

		log_success "WAV files staged for $pdf_name."

		# Reset and find WAV files
		SORTED_WAVS=()
		find_and_sort_wav_files "$project_temp_dir"

		if [[ ${#SORTED_WAVS[@]} -eq 0 ]]; then
			log_error "No valid WAV files found in staged directory for $pdf_name: $project_temp_dir"
			return 1
		fi
		log_info "Found ${#SORTED_WAVS[@]} valid WAV files for $pdf_name."

		declare final_wav_output="$project_temp_dir/${pdf_name}_final.wav"
		declare final_mp3_output="$OUTPUT_DIR/$pdf_name/mp3/${pdf_name}.mp3"
		declare final_dir_output="$OUTPUT_DIR/$pdf_name/mp3"

		declare mkdir_output=""
		declare mkdir_exit_code=""
		mkdir_output=$(mkdir -p "$final_dir_output")
		mkdir_exit_code="$?"

		if [[ $mkdir_exit_code -ne 0 ]]; then
			log_error "Failed to create MP3 output directory: $final_dir_output - $mkdir_output"
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
	OUTPUT_DIR=$(helpers/get_config_helper.sh "paths.output_dir")
	INPUT_DIR=$(helpers/get_config_helper.sh "paths.output_dir")
	PROCESSING_DIR=$(helpers/get_config_helper.sh "processing_dir.combine_chunks")
	LOG_DIR=$(helpers/get_config_helper.sh "logs_dir.combine_chunks")

	# Setup logging
	declare mkdir_log_output=""
	declare mkdir_log_exit_code=""
	mkdir_log_output=$(mkdir -p "$LOG_DIR")
	mkdir_log_exit_code="$?"

	if [[ $mkdir_log_exit_code -ne 0 ]]; then
		echo "ERROR: Failed to create log directory: $LOG_DIR - $mkdir_log_output"
		exit 1
	fi

	LOG_FILE="$LOG_DIR/log_$(date +'%Y%m%d_%H%M%S').log"
	FAILED_LOG="$LOG_DIR/failed_projects.log"
	declare -r logger="helpers/logging_utils_helper.sh"
	source "$logger"

	declare touch_output=""
	declare touch_exit_code=""
	touch_output=$(touch "$LOG_FILE" "$FAILED_LOG")
	touch_exit_code="$?"

	if [[ $touch_exit_code -ne 0 ]]; then
		echo "ERROR: Failed to create log files: $touch_output"
		exit 1
	fi

	log_info "Script started. Log file: $LOG_FILE"

	trap 'cleanup_and_exit' EXIT INT TERM
	check_dependencies

	# Process all PDF projects with valid WAV directories
	declare -a pdf_dirs=()

	# Find directories in INPUT_DIR where the WAV subdirectory exists
	declare find_pdf_output=""
	find_pdf_output=$(find "$INPUT_DIR" -type f -name "*.pdf" -exec basename {} .pdf \;)

	if [[ -z $find_pdf_output ]]; then
		log_warn "No PDF projects found in $INPUT_DIR"
		exit 0
	fi

	mapfile -t pdf_dirs <<<"$find_pdf_output"

	log_info "Found ${#pdf_dirs[@]} PDF projects"

	declare pdf_name=""
	for pdf_name in "${pdf_dirs[@]}"; do
		SORTED_WAVS=()
		echo "INFO: CLEANED OLD PROCESSING_DIR"
		declare rm_processing_output=""
		rm_processing_output=$(rm -rf "$PROCESSING_DIR")
		if [[ $rm_processing_output -ne 0 ]]; then
			echo "WARN: Failed to remove processing dir"
		fi

		echo "INFO: Creating new PROCESSING_DIR"
		declare processing_dir="$PROCESSING_DIR/$pdf_name/wav"

		declare mkdir_proc_output=""
		declare mkdir_proc_exit_code=""
		mkdir_proc_output=$(mkdir -p "$processing_dir")
		mkdir_proc_exit_code="$?"

		if [[ $mkdir_proc_exit_code -ne 0 ]]; then
			log_error "Failed to create processing directory: $processing_dir - $mkdir_proc_output"
			echo "$pdf_name" >>"$FAILED_LOG"
			continue
		fi

		declare process_exit_code=""
		process_pdf_project "$pdf_name" "$processing_dir"
		process_exit_code="$?"

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
