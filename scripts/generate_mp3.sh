#!/usr/bin/env bash
# generate_final_mp3.sh
# Design: Niko Nikolov
# Code: Various LLMs + Niko

set -euo pipefail
# --- Global Variables (declared at top) ---
declare CONFIG_HELPER_GLOBAL=""
declare FAILED_LOG_GLOBAL=""
declare INPUT_DIR_GLOBAL=""
declare LOG_DIR_GLOBAL=""
declare LOG_FILE_GLOBAL=""
declare LOGGER_SCRIPT_GLOBAL=""
declare OUTPUT_DIR_GLOBAL=""
declare PROCESSING_DIR_GLOBAL=""
declare -a PDF_PROJECTS_GLOBAL=()

# --- Dependency Check ---
check_dependencies() {
    local cmd_path=""
    local dep=""
    declare -a deps=("ffmpeg" "rsync" "sort" "yq" "flock")

    for dep in "${deps[@]}"; do
        cmd_path=$(command -v "$dep")
        if [[ -z $cmd_path ]]; then
            printf 'ERROR: "%s" is not installed.\n' "$dep" >&2
            exit 1
        fi
    done
    log_success "All dependencies are available."
}

# --- Find & Sort WAV Files ---
find_and_sort_wav_files() {
    local search_dir="$1"
    local find_output=""
    declare -n sorted_array_ref="$2"

    if [[ ! -d $search_dir ]]; then
        return 1
    fi

    find_output=$(find "$search_dir" -maxdepth 1 -name "*.wav" -type f | sort -V 2>&1)

    if [[ -z $find_output ]]; then
        return 1
    fi

    mapfile -t sorted_array_ref <<<"$find_output"

    if [[ ${#sorted_array_ref[@]} -gt 0 ]]; then
        log_info "Array was sorted"
        return 0
    else
        return 1
    fi
}

# --- Check if resampled files exist and match original count ---
check_resampled_files() {
    local resampled_count=""
    local resampled_dir="$1"
    local wav_count=""
    local wav_dir="$2"

    if [[ ! -d $resampled_dir ]]; then
        return 1
    fi

    wav_count=$(find "$wav_dir" -maxdepth 1 -name "*.wav" -type f | wc -l)
    resampled_count=$(find "$resampled_dir" -maxdepth 1 -name "*.wav" -type f | wc -l)

    if [[ $resampled_count -gt 0 && $resampled_count -eq $wav_count ]]; then
        log_info "Found resampled wav files"
        return 0
    else
        return 1
    fi
}

# --- Merge WAV Files (Order-Preserving) ---
merge_wav_files() {
    local project_temp_dir="$1"
    local output_file="$2"
    local pdf_name="$3"
    local base_name=""
    local ffmpeg_exit=""
    local ffmpeg_output=""
    local find_exit=""
    local find_output=""
    local i=0
    local input_file=""
    local mkdir_exit=""
    local mkdir_output=""
    local original_wav_dir="$OUTPUT_DIR_GLOBAL/$pdf_name/wav"
    local persistent_file=""
    local persistent_resample_dir="$OUTPUT_DIR_GLOBAL/$pdf_name/resampled"

    local concat_list_file="$project_temp_dir/concat_list.txt"
    local resampled_file=""
    local rsync_exit=""
    local rsync_output=""
    local wav_file=""
    declare -a local_sorted_wavs=()
    declare -a resampled_files=()
    touch "$concat_list_file"

    # Find and sort original WAV files
    find_exit=1
    find_and_sort_wav_files "$original_wav_dir" local_sorted_wavs
    find_exit="$?"

    if [[ $find_exit -ne 0 ]]; then
        log_error "No WAV files found or sorting failed for $pdf_name"
        return 1
    fi
    log_info "Verify if there are already resampled files"

    check_resampled_files "$persistent_resample_dir" "$original_wav_dir"
    resample_status="$?"
    # Check if resampled files already exist
    if [[ $resample_status -eq 0 ]]; then
        log_info "Resampled files exist for $pdf_name, using existing files"

        # Get sorted list of existing resampled files
        find_and_sort_wav_files "$persistent_resample_dir" resampled_files
        find_exit="$?"

        if [[ $find_exit -ne 0 ]]; then
            log_error "No resampled files found in $persistent_resample_dir"
            return 1
        fi

        # Generate concat list from existing resampled files
        for wav_file in "${resampled_files[@]}"; do
            printf 'file %s\n' "$wav_file" >>"$concat_list_file"
        done
    else
        log_info "Resampling WAV files for $pdf_name"

        # Create persistent resample directory
        mkdir_output=$(mkdir -p "$persistent_resample_dir" 2>&1)
        mkdir_exit="$?"

        if [[ $mkdir_exit -ne 0 ]]; then
            log_error "Failed to create persistent resample dir: $mkdir_output"
            return 1
        fi

        # Resample each file in sorted order and build concat list
        for ((i = 0; i < ${#local_sorted_wavs[@]}; i = i + 1)); do
            input_file="${local_sorted_wavs[i]}"
            base_name=$(basename "$input_file")
            resampled_file="$project_temp_dir/$base_name"
            persistent_file="$persistent_resample_dir/$base_name"

            log_info "Resampling: $base_name"

            ffmpeg -i "$input_file" \
                -ar 48000 -ac 1 -c:a pcm_s32le \
                -af "aresample=async=1:first_pts=0" \
                -rf64 auto \
                -hide_banner -loglevel error -y \
                "$resampled_file"
            ffmpeg_exit="$?"

            if [[ $ffmpeg_exit -ne 0 ]]; then
                log_error "Resampling failed for $input_file: $ffmpeg_output"
                return 1
            fi

            rsync -a "$resampled_file" "$persistent_file"
            rsync_exit="$?"

            if [[ $rsync_exit -ne 0 ]]; then
                log_error "Failed to sync resampled file: $rsync_output"
                return 1
            fi
            log_info "Adding $persistent_file to concat_list"
            printf 'file %s\n' "$persistent_file" >>"$concat_list_file"

        done
    fi

    log_info "Generated concat list for $pdf_name"

    # Debug: Show concat list contents
    if [[ -f $concat_list_file ]]; then
        log_info "Concat list contents:"
        while IFS= read -r line; do
            log_info "  $line"
        done <"$concat_list_file"
    fi

    # Merge all resampled files
    ffmpeg -f concat -safe 0 -i "$concat_list_file" \
        -c copy -avoid_negative_ts make_zero \
        -fflags +genpts -max_muxing_queue_size 4096 \
        -rf64 auto \
        -hide_banner -loglevel error -y \
        "$output_file"
    ffmpeg_exit="$?"

    if [[ $ffmpeg_exit -ne 0 ]]; then
        log_error "Merge failed for $pdf_name: $ffmpeg_output"
        return 1
    fi

    log_success "Merged WAV: $output_file"
    return 0
}

# --- Convert to MP3 ---
convert_to_mp3() {
    local ffmpeg_exit=""
    local ffmpeg_output=""
    local input_wav="$1"
    local output_mp3="$2"

    if [[ ! -f $input_wav ]]; then
        log_error "Input WAV missing: $input_wav"
        return 1
    fi

    ffmpeg_output=$(ffmpeg -i "$input_wav" \
        -c:a libmp3lame -q:a 0 \
        -hide_banner -loglevel error -y \
        "$output_mp3" 2>&1)
    ffmpeg_exit="$?"

    if [[ $ffmpeg_exit -eq 0 ]]; then
        log_success "MP3 created: $output_mp3"
        return 0
    else
        log_error "MP3 conversion failed: $ffmpeg_output"
        return 1
    fi
}

# --- Process One PDF Project ---
process_pdf_project() {

    local merge_exit=""
    local mkdir_exit=""
    local mkdir_output=""
    local pdf_name="$1"
    local final_mp3_dir="$OUTPUT_DIR_GLOBAL/$pdf_name/mp3"
    local project_temp_dir="$2"
    local project_wav_dir="$OUTPUT_DIR_GLOBAL/$pdf_name/wav"
    local final_mp3="$final_mp3_dir/${pdf_name}.mp3"
    local final_wav="$project_temp_dir/${pdf_name}_final.wav"

    log_info "Processing project: $pdf_name"

    if [[ ! -d $project_wav_dir ]]; then
        log_info "SKIPPING: No WAV directory for $pdf_name"
        return 0
    fi

    mkdir_output=$(mkdir -p "$final_mp3_dir" 2>&1)
    mkdir_exit="$?"

    if [[ $mkdir_exit -ne 0 ]]; then
        log_error "Failed to create MP3 dir: $mkdir_output"
        return 1
    fi

    merge_wav_files "$project_temp_dir" "$final_wav" "$pdf_name"
    merge_exit="$?"

    if [[ $merge_exit -ne 0 ]]; then
        log_error "Failed to merge WAV files for $pdf_name"
        return 1
    fi

    if [[ ! -f $final_wav ]]; then
        log_error "Final WAV file not created: $final_wav"
        return 1
    fi

    convert_to_mp3 "$final_wav" "$final_mp3"
    local convert_to_mp3_exit="$?"
    if [[ convert_to_mp3_exit -eq 0 ]]; then
        log_success "Completed project: $pdf_name"
        return 0
    else
        log_error "Failed to convert to MP3 for $pdf_name"
        return 1
    fi
}

# --- Cleanup on Exit ---
cleanup_and_exit() {
    if [[ -n $PROCESSING_DIR_GLOBAL && -d $PROCESSING_DIR_GLOBAL ]]; then
        rm -rf "${PROCESSING_DIR_GLOBAL:?}"
        log_info "Cleaned up processing directory: $PROCESSING_DIR_GLOBAL"
    fi
}

# --- Main ---
main() {
    local config_exit=""
    local find_exit=""
    local find_pdf_output=""
    local mkdir_exit=""
    local mkdir_output=""
    local pdf_name=""
    local project_temp_dir=""
    local process_exit=""

    # All global variable assignments at top
    CONFIG_HELPER_GLOBAL="helpers/get_config_helper.sh"
    LOGGER_SCRIPT_GLOBAL="helpers/logging_utils_helper.sh"
    source "$LOGGER_SCRIPT_GLOBAL"

    # Load config
    OUTPUT_DIR_GLOBAL=$("$CONFIG_HELPER_GLOBAL" "paths.output_dir" 2>&1)
    config_exit="$?"
    if [[ $config_exit -ne 0 ]]; then
        printf 'ERROR: Failed to get output_dir from config: %s\n' "$OUTPUT_DIR_GLOBAL" >&2
        exit 1
    fi

    INPUT_DIR_GLOBAL=$("$CONFIG_HELPER_GLOBAL" "paths.input_dir" 2>&1)
    config_exit="$?"
    if [[ $config_exit -ne 0 ]]; then
        printf 'ERROR: Failed to get input_dir from config: %s\n' "$INPUT_DIR_GLOBAL" >&2
        exit 1
    fi

    PROCESSING_DIR_GLOBAL=$("$CONFIG_HELPER_GLOBAL" "processing_dir.combine_chunks" 2>&1)
    config_exit="$?"
    if [[ $config_exit -ne 0 ]]; then
        printf 'ERROR: Failed to get processing_dir from config: %s\n' "$PROCESSING_DIR_GLOBAL" >&2
        exit 1
    fi

    LOG_DIR_GLOBAL=$("$CONFIG_HELPER_GLOBAL" "logs_dir.combine_chunks" 2>&1)
    config_exit="$?"
    if [[ $config_exit -ne 0 ]]; then
        printf 'ERROR: Failed to get logs_dir from config: %s\n' "$LOG_DIR_GLOBAL" >&2
        exit 1
    fi

    # Setup logging
    mkdir_output=$(mkdir -p "$LOG_DIR_GLOBAL" 2>&1)
    mkdir_exit="$?"

    if [[ $mkdir_exit -ne 0 ]]; then
        printf 'ERROR: Failed to create log directory: %s\n' "$mkdir_output" >&2
        exit 1
    fi

    LOG_FILE_GLOBAL="$LOG_DIR_GLOBAL/log_$(date +'%Y%m%d_%H%M%S').log"
    FAILED_LOG_GLOBAL="$LOG_DIR_GLOBAL/failed_projects.log"

    LOG_FILE="$LOG_FILE_GLOBAL"
    export LOG_FILE

    # Source logger
    if [[ ! -f $LOGGER_SCRIPT_GLOBAL ]]; then
        printf 'ERROR: Logging helper not found: %s\n' "$LOGGER_SCRIPT_GLOBAL" >&2
        exit 1
    fi

    # Initialize log files
    if [[ ! -f $LOG_FILE_GLOBAL ]]; then
        touch "$LOG_FILE_GLOBAL"
    fi
    if [[ ! -f $FAILED_LOG_GLOBAL ]]; then
        touch "$FAILED_LOG_GLOBAL"
    fi

    log_info "MP3 generation started"

    trap 'cleanup_and_exit' EXIT INT TERM

    check_dependencies

    # Discover projects
    find_pdf_output=$(find "$INPUT_DIR_GLOBAL" -type f -name "*.pdf" -exec basename {} .pdf \; 2>&1)
    find_exit="$?"

    if [[ $find_exit -ne 0 || -z $find_pdf_output ]]; then
        log_warn "No PDF projects found in $INPUT_DIR_GLOBAL"
        exit 0
    fi

    mapfile -t PDF_PROJECTS_GLOBAL <<<"$find_pdf_output"
    log_info "Discovered ${#PDF_PROJECTS_GLOBAL[@]} projects for processing"

    # Create base processing dir
    mkdir_output=$(mkdir -p "$PROCESSING_DIR_GLOBAL" 2>&1)
    mkdir_exit="$?"

    if [[ $mkdir_exit -ne 0 ]]; then
        log_error "Failed to create processing directory: $mkdir_output"
        exit 1
    fi

    # Process each project sequentially
    for pdf_name in "${PDF_PROJECTS_GLOBAL[@]}"; do
        project_temp_dir="$PROCESSING_DIR_GLOBAL/$pdf_name"

        mkdir_output=$(mkdir -p "$project_temp_dir" 2>&1)
        mkdir_exit="$?"

        if [[ $mkdir_exit -ne 0 ]]; then
            log_error "Failed to create temp dir for $pdf_name: $mkdir_output"
            printf '%s\n' "$pdf_name" >>"$FAILED_LOG_GLOBAL"
            continue
        fi

        process_pdf_project "$pdf_name" "$project_temp_dir"
        process_exit="$?"

        if [[ $process_exit -ne 0 ]]; then
            log_error "Failed to process project: $pdf_name"
            printf '%s\n' "$pdf_name" >>"$FAILED_LOG_GLOBAL"
        fi

        # Clean up project temp dir
        rm -rf "$project_temp_dir"
    done

    log_success "Processing complete."
    print_line
}

# --- Entry Point ---
main "$@"
