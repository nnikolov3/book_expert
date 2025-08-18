#!/usr/bin/env bash

# Comprehensive Testing Pipeline
# Following design principles: "Test, test, test" and "Fast is slow, no cutting corners"
# Purpose: Lint, test, and validate all source files with comprehensive checks

set -euo pipefail

# Global constants
declare SCRIPT_DIR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
declare -r SCRIPT_DIR
declare PROJECT_ROOT
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
declare -r PROJECT_ROOT
declare -r LOG_DIR="${PROJECT_ROOT}/logs/pipeline"
declare TIMESTAMP
TIMESTAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
declare -r TIMESTAMP
declare -r LOG_FILE="${LOG_DIR}/pipeline_${TIMESTAMP}.log"

# Colors for output (only when TTY)
if [[ -t 1 ]]; then
    declare -r RED='\033[0;31m'
    declare -r GREEN='\033[0;32m'
    declare -r YELLOW='\033[1;33m'
    declare -r BLUE='\033[0;34m'
    declare -r NC='\033[0m' # No Color
else
    declare -r RED=''
    declare -r GREEN=''
    declare -r YELLOW=''
    declare -r BLUE=''
    declare -r NC=''
fi

# Pipeline configuration
declare -g PROFILE=0
declare -g QUICK=0
declare -ga FAILED_CHECKS=()
declare -gi EXIT_CODE=0

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $*" >&2; echo "[$(date)] INFO: $*" >> "${LOG_FILE}"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; echo "[$(date)] WARN: $*" >> "${LOG_FILE}"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; echo "[$(date)] ERROR: $*" >> "${LOG_FILE}"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $*" >&2; echo "[$(date)] PASS: $*" >> "${LOG_FILE}"; }

usage()
{
    cat << EOF
Usage: $0 [OPTIONS]

Comprehensive testing pipeline for book_expert project.

OPTIONS:
    --profile, -p     Enable code profiling
    --quick, -q       Quick mode (skip heavy tests)
    --help, -h        Show this help message

EXAMPLES:
    $0                    # Run full pipeline
    $0 --quick            # Run essential checks only
    $0 --profile          # Run with profiling enabled

EOF
}

# Parse command line arguments
parse_args()
{
    while [[ $# -gt 0 ]]; do
        case $1 in
            --profile|-p)
                PROFILE=1
                shift
                ;;
            --quick|-q)
                QUICK=1
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# Setup pipeline environment
setup_environment()
{
    # ALL local variables at the top of function
    local required_tools=("go" "shellcheck" "jq" "yq")
    local missing_tools=()
    local tool_check_output=""
    local tool_check_exit=""
    
    mkdir -p "${LOG_DIR}"
    
    # Change to project root
    cd "${PROJECT_ROOT}"
    
    log_info "Starting pipeline in: ${PROJECT_ROOT}"
    log_info "Log file: ${LOG_FILE}"
    
    # Check required tools
    for tool in "${required_tools[@]}"; do
        tool_check_output=$(command -v "${tool}" 2>&1)
        tool_check_exit="$?"
        
        if [[ "$tool_check_exit" -eq 0 ]]; then
            log_info "Found ${tool} at ${tool_check_output}"
        else
            missing_tools+=("${tool}")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        exit 1
    fi
}

# Record failure and continue
record_failure()
{
    local check_name="$1"
    local error_msg="$2"
    
    FAILED_CHECKS+=("${check_name}: ${error_msg}")
    EXIT_CODE=1
    log_error "${check_name} FAILED: ${error_msg}"
}

# Go code quality checks
check_go_code()
{
    # ALL local variables at the top of function
    local vet_output=""
    local build_output=""
    local lint_output=""
    local static_output=""
    local vet_check_exit=""
    local build_check_exit=""

    log_info "Running Go code quality checks..."

    # Go formatting check
    local unformatted
    unformatted=$(find . -name "*.go" -not -path "./vendor/*" -not -path "./.git/*" -not -path "./TTS/*" -not -path "./.venv/*" -print0 | xargs -0 gofmt -l)
    if [[ -z "${unformatted}" ]]; then
        log_success "Go formatting check passed"
    else
        record_failure "Go Formatting" "Files need formatting:\n${unformatted}"
    fi

    # Go imports check
    if command -v goimports >/dev/null 2>&1; then
        unformatted=$(find . -name "*.go" -not -path "./vendor/*" -not -path "./.git/*" -not -path "./TTS/*" -not -path "./.venv/*" -print0 | xargs -0 goimports -l)
        if [[ -z "${unformatted}" ]]; then
            log_success "Go imports check passed"
        else
            record_failure "Go Imports" "Files need import formatting:\n${unformatted}"
        fi
    fi

    # Go vet
    vet_output=$(go vet ./... 2>&1)
    vet_check_exit="$?"
    log_info "Go vet output:\n${vet_output}"
    if [[ "$vet_check_exit" -eq 0 ]]; then
        log_success "Go vet check passed"
    else
        record_failure "Go Vet" "${vet_output}"
    fi

    # Go build test
    build_output=$(go build ./... 2>&1)
    build_check_exit="$?"
    log_info "Go build output:\n${build_output}"
    if [[ "$build_check_exit" -eq 0 ]]; then
        log_success "Go build check passed"
    else
        record_failure "Go Build" "${build_output}"
    fi

    # Advanced linting (if available)
    if command -v golangci-lint >/dev/null 2>&1; then
        lint_output=$(golangci-lint run --timeout=5m 2>&1 | head -20)
        lint_exit="$?"
        log_info "golangci-lint output:\n${lint_output}"
        if [[ "$lint_exit" -eq 0 ]]; then
            log_success "golangci-lint check passed"
        else
            record_failure "golangci-lint" "${lint_output}"
        fi
    fi

    # Static analysis (if available)
    if command -v staticcheck >/dev/null 2>&1; then
        static_output=$(staticcheck ./... 2>&1 | head -10)
        static_exit="$?"
        log_info "staticcheck output:\n${static_output}"
        if [[ "$static_exit" -eq 0 ]]; then
            log_success "staticcheck passed"
        else
            record_failure "staticcheck" "${static_output}"
        fi
    fi
}

# Go unit tests with profiling
run_go_tests()
{
    log_info "Running Go unit tests..."
    
    if [[ ! -d "./cmd" ]] && [[ ! -f "go.mod" ]]; then
        log_info "No Go modules found, skipping Go tests"
        return 0
    fi
    
    local test_args=("-v")
    local profile_args=()
    
    if [[ ${PROFILE} -eq 1 ]]; then
        profile_args+=("-cpuprofile=logs/pipeline/cpu.prof")
        profile_args+=("-memprofile=logs/pipeline/mem.prof")
        profile_args+=("-bench=.")
        log_info "Profiling enabled"
    fi
    
    if [[ ${QUICK} -eq 0 ]]; then
        test_args+=("-race")
        test_args+=("-cover")
    fi
    
    # Run tests
    if go test "${test_args[@]}" "${profile_args[@]}" ./... >/dev/null 2>&1; then
        log_success "Go unit tests passed"
        
        # Display coverage if available
        if [[ ${QUICK} -eq 0 ]]; then
            local coverage_output
            coverage_output=$(go test -cover ./... 2>/dev/null | grep -o 'coverage: [0-9.]*%' || echo "")
            if [[ -n "${coverage_output}" ]]; then
                log_info "Test ${coverage_output}"
            fi
        fi
    else
        local test_output
        test_output=$(go test "${test_args[@]}" ./... 2>&1 | tail -20)
        record_failure "Go Unit Tests" "${test_output}"
    fi
}

# Bash script quality checks
check_bash_scripts()
{
    log_info "Running Bash script quality checks..."
    
    local bash_files
    bash_files=$(find . -name "*.sh" -not -path "./.git/*" -not -path "./vendor/*" -not -path "./TTS/*" -not -path "./.venv/*")
    
    if [[ -z "${bash_files}" ]]; then
        log_info "No Bash scripts found, skipping Bash checks"
        return 0
    fi
    
    # ShellCheck analysis
    local shellcheck_output=""
    
    shellcheck_output=$(find . -name "*.sh" -not -path "./.git/*" -not -path "./vendor/*" -not -path "./TTS/*" -not -path "./.venv/*" -print0 | xargs -0 -r shellcheck -f gcc || true)
    if [[ -z "${shellcheck_output}" ]]; then
        log_success "ShellCheck analysis passed"
    else
        record_failure "ShellCheck" "${shellcheck_output}"
    fi
    
    # Bash syntax check
    local syntax_output=""
    
    syntax_output=$(find . -name "*.sh" -not -path "./.git/*" -not -path "./vendor/*" -not -path "./TTS/*" -not -path "./.venv/*" -print0 | xargs -0 -r -n 1 bash -n 2>&1 || true)
    if [[ -z "${syntax_output}" ]]; then
        log_success "Bash syntax check passed"
    else
        record_failure "Bash Syntax" "${syntax_output}"
    fi
}

# Project configuration validation
check_project_config()
{
    log_info "Checking project configuration..."
    
    # Check project.toml
    if [[ -f "project.toml" ]]; then
        if yq -p toml eval '.' project.toml >/dev/null 2>&1; then
            log_success "project.toml syntax valid"
        else
            local toml_error
            toml_error=$(yq -p toml eval '.' project.toml 2>&1)
            record_failure "project.toml" "${toml_error}"
        fi
    fi
    
    # Check go.mod
    if [[ -f "go.mod" ]]; then
        if go mod verify >/dev/null 2>&1; then
            log_success "go.mod verification passed"
        else
            local mod_error
            mod_error=$(go mod verify 2>&1)
            record_failure "go.mod" "${mod_error}"
        fi
    fi
    
    # Check required directories exist
    local required_dirs=("scripts" "cmd" "logs")
    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "${dir}" ]]; then
            record_failure "Directory Structure" "Missing required directory: ${dir}"
        fi
    done
}

# Code complexity and quality metrics
run_code_metrics()
{
    if [[ ${QUICK} -eq 1 ]]; then
        log_info "Skipping code metrics in quick mode"
        return 0
    fi
    
    log_info "Running code quality metrics..."
    
    # Go code complexity (if gocyclo is available)
    if command -v gocyclo >/dev/null 2>&1; then
        local complex_funcs
        complex_funcs=$(gocyclo -over 10 . 2>/dev/null || echo "")
        if [[ -n "${complex_funcs}" ]]; then
            log_warn "High complexity functions detected:\n${complex_funcs}"
        else
            log_success "Code complexity check passed"
        fi
    fi
    
    # Line count statistics
    local go_lines bash_lines total_lines
    go_lines=$(find . -name "*.go" -not -path "./.git/*" -exec wc -l {} + 2>/dev/null | tail -1 | awk '{print $1}' || echo "0")
    bash_lines=$(find . -name "*.sh" -not -path "./.git/*" -exec wc -l {} + 2>/dev/null | tail -1 | awk '{print $1}' || echo "0")
    total_lines=$((go_lines + bash_lines))
    
    log_info "Code statistics: ${total_lines} total lines (Go: ${go_lines}, Bash: ${bash_lines})"
}

# Git hooks setup
setup_git_hooks()
{
    log_info "Setting up git hooks..."
    
    if [[ ! -d ".git" ]]; then
        log_info "Not a git repository, skipping git hooks setup"
        return 0
    fi
    
    # Create pre-commit hook
    local pre_commit_hook=".git/hooks/pre-commit"
    cat > "${pre_commit_hook}" << 'EOF'
#!/bin/bash
# Auto-generated pre-commit hook
exec ./scripts/test_pipeline.sh --quick
EOF
    
    chmod +x "${pre_commit_hook}"
    log_success "Git pre-commit hook installed"
    
    # Create pre-push hook
    local pre_push_hook=".git/hooks/pre-push"
    cat > "${pre_push_hook}" << 'EOF'
#!/bin/bash
# Auto-generated pre-push hook
exec ./scripts/test_pipeline.sh
EOF
    
    chmod +x "${pre_push_hook}"
    log_success "Git pre-push hook installed"
}

# Generate profiling report
generate_profile_report()
{
    if [[ ${PROFILE} -eq 0 ]]; then
        return 0
    fi
    
    log_info "Generating profiling report..."
    
    if [[ -f "logs/pipeline/cpu.prof" ]]; then
        if command -v go >/dev/null 2>&1; then
            log_info "CPU profile available at: logs/pipeline/cpu.prof"
            log_info "View with: go tool pprof logs/pipeline/cpu.prof"
        fi
    fi
    
    if [[ -f "logs/pipeline/mem.prof" ]]; then
        log_info "Memory profile available at: logs/pipeline/mem.prof"
        log_info "View with: go tool pprof logs/pipeline/mem.prof"
    fi
}

# Pipeline summary
print_summary()
{
    echo
    echo "========================================="
    echo "          PIPELINE SUMMARY"
    echo "========================================="
    
    if [[ ${#FAILED_CHECKS[@]} -eq 0 ]]; then
        log_success "All checks passed! ✅"
        echo
        log_info "Pipeline completed successfully in ${PROJECT_ROOT}"
        if [[ ${PROFILE} -eq 1 ]]; then
            echo
            log_info "Profiling data saved to logs/pipeline/"
        fi
    else
        log_error "Pipeline failed with ${#FAILED_CHECKS[@]} errors:"
        echo
        for failure in "${FAILED_CHECKS[@]}"; do
            echo -e "  ${RED}✗${NC} ${failure}"
        done
        echo
        log_error "Check the log file for details: ${LOG_FILE}"
    fi
    
    echo "========================================="
}

# Main pipeline execution
main()
{
	# ALL local variables at the top of function
	local shellcheck_output=""

	parse_args "$@"
	setup_environment

	# Only show verbose output if requested or if there are failures
	temp_log=$(mktemp)

	{
		check_project_config
		check_bash_scripts
		check_go_code
		run_go_tests
		# Minimal bash script validation (we have very few left)
		log_info "Checking remaining bash scripts..."
		shellcheck_output=$(find scripts/ -name "*.sh" -exec shellcheck {} \; 2>&1)
		# shellcheck disable=SC2181
		if [[ "$?" -eq 0 ]]; then
			log_success "Remaining bash scripts pass shellcheck"
		else
			record_failure "ShellCheck" "Some bash scripts have issues: $shellcheck_output"
		fi
		run_code_metrics
		setup_git_hooks
		generate_profile_report
	} > "${temp_log}" 2>&1

	# Show output only if verbose or if there were failures
	if [[ ${EXIT_CODE} -ne 0 ]]; then
		cat "${temp_log}"
	fi

	rm -f "${temp_log}"

	print_summary

	exit ${EXIT_CODE}
}

# Error handling
trap 'log_error "Pipeline interrupted"; exit 130' INT
trap 'log_error "Pipeline terminated"; exit 143' TERM

# Run main function
main "$@"