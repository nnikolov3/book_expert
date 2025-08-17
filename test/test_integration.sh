#!/usr/bin/env bash

# Integration Test Suite for book_expert project
# Following design principles: "Test, confirm, validate, improve, and repeat"

set -euo pipefail

# Test configuration
declare SCRIPT_DIR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
declare PROJECT_ROOT
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly PROJECT_ROOT
readonly TEST_DATA_DIR="$SCRIPT_DIR/test_data"
readonly TEMP_DIR="/tmp/book_expert_test_$$"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# Test framework functions
run_test() {
    local test_name="$1"
    local test_function="$2"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    echo
    log_info "Running test: $test_name"
    
    if $test_function; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        log_info "✓ PASSED: $test_name"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_error "✗ FAILED: $test_name"
    fi
}

# Setup and teardown
setup_test_env() {
    log_info "Setting up test environment..."
    mkdir -p "$TEMP_DIR"
    mkdir -p "$TEST_DATA_DIR"
    
    # Create test JSON file
    cat > "$TEST_DATA_DIR/test_book.json" << 'EOF'
{
    "file_name": "test_book.json",
    "file_hash": "test123",
    "processed_date": "2025-08-14T01:00:00.000000",
    "total_pages": 1,
    "processed": "2025-08-14",
    "name": "Test Book",
    "content": {
        "ocr": "This is test OCR content with some technical information.",
        "pdf_text": "This is test PDF text content."
    }
}
EOF
}

teardown_test_env() {
    log_info "Cleaning up test environment..."
    rm -rf "$TEMP_DIR"
}

# Integration Test 1: Skip legacy Cerebras enhancement test  
test_cerebras_enhancement_integration() {
    log_info "Skipping legacy Cerebras enhancement test (helper scripts removed)"
    return 0
}

# Integration Test 2: llama-embedding Binary
test_llama_embedding_integration() {
    local input_file="$TEMP_DIR/embedding_test.txt"
    
    echo "Test embedding content" > "$input_file"
    
    # Check if llama-embedding binary exists
    if [[ ! -x "$PROJECT_ROOT/bin/llama-embedding" ]]; then
        log_warn "llama-embedding binary not found, skipping test"
        return 0
    fi
    
    # Check if model exists
    if [[ ! -f "$PROJECT_ROOT/models/Qwen3-Embedding-4B-Q8_0.gguf" ]]; then
        log_warn "Embedding model not found, skipping test"
        return 0
    fi
    
    # Test embedding generation
    if output=$("$PROJECT_ROOT/bin/llama-embedding" \
        -m "$PROJECT_ROOT/models/Qwen3-Embedding-4B-Q8_0.gguf" \
        -f "$input_file" \
        --embedding 2>/dev/null); then
        
        # Validate output is JSON array
        if echo "$output" | jq -e 'type == "array"' >/dev/null 2>&1; then
            local dim
            dim=$(echo "$output" | jq 'length')
            if [[ "$dim" -eq 2560 ]]; then
                log_info "Embedding generation successful, correct dimensions: $dim"
                return 0
            else
                log_error "Wrong embedding dimensions: $dim (expected 2560)"
                return 1
            fi
        else
            log_error "Invalid embedding output format"
            return 1
        fi
    else
        log_error "Embedding generation failed"
        return 1
    fi
}



# Integration Test 5: Skip legacy configuration helper test
test_config_helper() {
    log_info "Skipping legacy config helper test (helper scripts removed)"
    return 0
}

# Integration Test 6: Pipeline Dependencies
test_pipeline_dependencies() {
    local deps=(curl jq mktemp)
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done
    
    if [[ ${#missing_deps[@]} -eq 0 ]]; then
        log_info "All pipeline dependencies available"
        return 0
    else
        log_error "Missing dependencies: ${missing_deps[*]}"
        return 1
    fi
}

# Integration Test 7: File System Structure
test_filesystem_structure() {
    local required_dirs=("scripts" "cmd" "bin" "json")
    local missing_dirs=()
    
    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "$PROJECT_ROOT/$dir" ]]; then
            missing_dirs+=("$dir")
        fi
    done
    
    if [[ ${#missing_dirs[@]} -eq 0 ]]; then
        log_info "All required directories present"
        return 0
    else
        log_error "Missing directories: ${missing_dirs[*]}"
        return 1
    fi
}

# Main test execution
main() {
    echo "========================================"
    echo "book_expert Integration Test Suite"
    echo "========================================"
    
    setup_test_env
    trap teardown_test_env EXIT
    
    # Run all integration tests
    run_test "Pipeline Dependencies" test_pipeline_dependencies
    run_test "File System Structure" test_filesystem_structure
    run_test "Configuration Helper" test_config_helper
    run_test "llama-embedding Integration" test_llama_embedding_integration
    run_test "Cerebras Enhancement Integration" test_cerebras_enhancement_integration
    
    # Summary
    echo
    echo "========================================"
    echo "Test Summary"
    echo "========================================"
    echo "Tests Run:    $TESTS_RUN"
    echo "Tests Passed: $TESTS_PASSED"
    echo "Tests Failed: $TESTS_FAILED"
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        log_info "All tests passed! ✓"
        exit 0
    else
        log_error "Some tests failed! ✗"
        exit 1
    fi
}

# Run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi