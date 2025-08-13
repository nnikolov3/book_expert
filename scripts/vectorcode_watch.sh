#!/usr/bin/env bash
set -euo pipefail

# vectorcode_watch.sh
# Continuously monitor file changes and update vectorcode database
# Usage: ./vectorcode_watch.sh [interval_seconds]

declare -r SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
declare -r PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

declare WATCH_INTERVAL="${1:-10}"
declare -r VECTORCODE_CONFIG="$PROJECT_ROOT/.vectorcode"
declare -r LAST_UPDATE_FILE="$VECTORCODE_CONFIG/last_update"

function log_info() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $*"
}

function log_error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

function check_dependencies() {
    local missing_deps=()
    
    if ! command -v vectorcode >/dev/null 2>&1; then
        missing_deps+=("vectorcode")
    fi
    
    if ! command -v find >/dev/null 2>&1; then
        missing_deps+=("find")
    fi
    
    if [[ "${#missing_deps[@]}" -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        exit 1
    fi
}

function get_last_update_time() {
    if [[ -f "$LAST_UPDATE_FILE" ]]; then
        cat "$LAST_UPDATE_FILE"
    else
        echo "0"
    fi
}

function set_last_update_time() {
    local current_time="$1"
    echo "$current_time" > "$LAST_UPDATE_FILE"
}

function find_modified_files() {
    local last_update="$1"
    local modified_files=""
    
    # Find files modified since last update
    modified_files=$(find "$PROJECT_ROOT" \
        -type f \
        \( -name "*.sh" -o -name "*.go" -o -name "*.md" -o -name "*.toml" -o -name "*.py" \) \
        -not -path "$PROJECT_ROOT/.venv/*" \
        -not -path "$PROJECT_ROOT/data/*" \
        -not -path "$PROJECT_ROOT/examples/*" \
        -not -path "$PROJECT_ROOT/F5-TTS/*" \
        -not -path "$PROJECT_ROOT/models/*" \
        -not -path "$PROJECT_ROOT/bin/*" \
        -not -path "$PROJECT_ROOT/.git/*" \
        -not -path "$PROJECT_ROOT/.claude/*" \
        -newer "${last_update}" 2>/dev/null || true)
    
    echo "$modified_files"
}

function update_vectorcode() {
    local update_result=""
    
    log_info "Updating vectorcode database..."
    
    update_result=$(vectorcode update 2>&1)
    local update_exit="$?"
    
    if [[ "$update_exit" -eq 0 ]]; then
        log_info "Vectorcode database updated successfully"
        return 0
    else
        log_error "Vectorcode update failed: $update_result"
        return 1
    fi
}

function watch_files() {
    local last_update=""
    local current_time=""
    local modified_files=""
    
    log_info "Starting vectorcode file watcher (interval: ${WATCH_INTERVAL}s)"
    log_info "Monitoring: $PROJECT_ROOT"
    log_info "Press Ctrl+C to stop"
    
    # Initialize last update time if not exists
    if [[ ! -f "$LAST_UPDATE_FILE" ]]; then
        touch "$LAST_UPDATE_FILE"
        set_last_update_time "$LAST_UPDATE_FILE"
    fi
    
    while true; do
        current_time=$(date +%s)
        last_update=$(get_last_update_time)
        
        # Use the timestamp file as reference if it exists, otherwise use epoch
        if [[ -f "$LAST_UPDATE_FILE" ]]; then
            modified_files=$(find_modified_files "$LAST_UPDATE_FILE")
        else
            # First run - update everything
            modified_files="initial_run"
        fi
        
        if [[ -n "$modified_files" && "$modified_files" != "" ]]; then
            if [[ "$modified_files" == "initial_run" ]]; then
                log_info "Initial vectorcode database update"
            else
                log_info "Detected modified files, updating vectorcode database"
            fi
            
            if update_vectorcode; then
                set_last_update_time "$current_time"
                # Update the file timestamp for next find operation  
                touch "$LAST_UPDATE_FILE"
            fi
        fi
        
        sleep "$WATCH_INTERVAL"
    done
}

function main() {
    if [[ ! -d "$VECTORCODE_CONFIG" ]]; then
        log_error "Vectorcode not initialized in project. Run 'vectorcode init' first."
        exit 1
    fi
    
    check_dependencies
    
    # Change to project root
    cd "$PROJECT_ROOT"
    
    # Set up signal handling for clean exit
    trap 'log_info "File watcher stopped"; exit 0' INT TERM
    
    watch_files
}

main "$@"# Test comment for vectorcode update
