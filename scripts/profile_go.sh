#!/usr/bin/env bash

# Go Profiling and Performance Analysis
# Purpose: Comprehensive Go code profiling and performance metrics
# Following design principles: "Test, test, test" and "Make the common case fast"

set -euo pipefail

declare SCRIPT_DIR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
declare -r SCRIPT_DIR
declare PROJECT_ROOT
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
declare -r PROJECT_ROOT
declare -r PROFILE_DIR="${PROJECT_ROOT}/logs/profiles"
declare TIMESTAMP
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
declare -r TIMESTAMP

# Configuration
declare -g BENCHMARK_TIME="10s"
declare -g PROFILE_TYPE="all"
declare -g VERBOSE=0

usage()
{
    cat << EOF
Usage: $0 [OPTIONS]

Go profiling and performance analysis tool.

OPTIONS:
    --benchmark-time=TIME  Duration to run benchmarks (default: 10s)
    --profile=TYPE         Profile type: cpu, mem, mutex, block, or all (default: all)
    --verbose, -v          Enable verbose output
    --help, -h             Show this help message

EXAMPLES:
    $0                           # Run all profiles
    $0 --profile=cpu            # Run CPU profiling only
    $0 --benchmark-time=30s     # Run benchmarks for 30 seconds
    $0 --verbose               # Run with detailed output

PROFILE ANALYSIS:
    # View CPU profile
    go tool pprof logs/profiles/cpu_TIMESTAMP.prof
    
    # View memory profile  
    go tool pprof logs/profiles/mem_TIMESTAMP.prof
    
    # Generate web interface
    go tool pprof -http=:8080 logs/profiles/cpu_TIMESTAMP.prof

EOF
}

parse_args()
{
    while [[ $# -gt 0 ]]; do
        case $1 in
            --benchmark-time=*)
                BENCHMARK_TIME="${1#*=}"
                shift
                ;;
            --profile=*)
                PROFILE_TYPE="${1#*=}"
                shift
                ;;
            --verbose|-v)
                VERBOSE=1
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                usage
                exit 1
                ;;
        esac
    done
}

setup_environment()
{
    mkdir -p "${PROFILE_DIR}"
    cd "${PROJECT_ROOT}"
    
    if [[ ${VERBOSE} -eq 1 ]]; then
        echo "Profile directory: ${PROFILE_DIR}"
        echo "Benchmark duration: ${BENCHMARK_TIME}"
        echo "Profile type: ${PROFILE_TYPE}"
    fi
}

run_benchmarks()
{
    echo "Running Go benchmarks..."
    
    local benchmark_output="${PROFILE_DIR}/benchmark_${TIMESTAMP}.txt"
    
    # Run benchmarks with profiling
    local bench_args=()
    bench_args+=("-bench=.")
    bench_args+=("-benchtime=${BENCHMARK_TIME}")
    bench_args+=("-benchmem")
    
    if [[ "${PROFILE_TYPE}" == "all" ]] || [[ "${PROFILE_TYPE}" == "cpu" ]]; then
        bench_args+=("-cpuprofile=${PROFILE_DIR}/cpu_${TIMESTAMP}.prof")
    fi
    
    if [[ "${PROFILE_TYPE}" == "all" ]] || [[ "${PROFILE_TYPE}" == "mem" ]]; then
        bench_args+=("-memprofile=${PROFILE_DIR}/mem_${TIMESTAMP}.prof")
    fi
    
    if [[ "${PROFILE_TYPE}" == "all" ]] || [[ "${PROFILE_TYPE}" == "mutex" ]]; then
        bench_args+=("-mutexprofile=${PROFILE_DIR}/mutex_${TIMESTAMP}.prof")
    fi
    
    if [[ "${PROFILE_TYPE}" == "all" ]] || [[ "${PROFILE_TYPE}" == "block" ]]; then
        bench_args+=("-blockprofile=${PROFILE_DIR}/block_${TIMESTAMP}.prof")
    fi
    
    # Run the benchmarks
    if go test "${bench_args[@]}" ./... > "${benchmark_output}" 2>&1; then
        echo "✅ Benchmarks completed successfully"
        
        if [[ ${VERBOSE} -eq 1 ]]; then
            echo
            echo "Benchmark results:"
            cat "${benchmark_output}"
        fi
        
        # Summary of benchmark results
        echo
        echo "Benchmark summary:"
        grep -E "(Benchmark|PASS|FAIL)" "${benchmark_output}" | head -10 || echo "No benchmark results found"
        
    else
        echo "❌ Benchmarks failed"
        if [[ ${VERBOSE} -eq 1 ]]; then
            cat "${benchmark_output}"
        fi
        return 1
    fi
}

run_unit_test_profiling()
{
    echo "Running unit tests with profiling..."
    
    local test_args=()
    test_args+=("-v")
    test_args+=("-cover")
    
    if [[ "${PROFILE_TYPE}" == "all" ]] || [[ "${PROFILE_TYPE}" == "cpu" ]]; then
        test_args+=("-cpuprofile=${PROFILE_DIR}/test_cpu_${TIMESTAMP}.prof")
    fi
    
    if [[ "${PROFILE_TYPE}" == "all" ]] || [[ "${PROFILE_TYPE}" == "mem" ]]; then
        test_args+=("-memprofile=${PROFILE_DIR}/test_mem_${TIMESTAMP}.prof")
    fi
    
    local test_output="${PROFILE_DIR}/test_profile_${TIMESTAMP}.txt"
    
    if go test "${test_args[@]}" ./... > "${test_output}" 2>&1; then
        echo "✅ Test profiling completed"
        
        # Extract coverage information
        local coverage
        coverage=$(grep -o 'coverage: [0-9.]*%' "${test_output}" | tail -1 || echo "coverage: unknown")
        echo "Test ${coverage}"
        
    else
        echo "❌ Test profiling failed"
        if [[ ${VERBOSE} -eq 1 ]]; then
            cat "${test_output}"
        fi
        return 1
    fi
}

generate_profile_analysis()
{
    echo "Generating profile analysis..."
    
    # Find generated profiles
    local profiles
    profiles=$(find "${PROFILE_DIR}" -name "*_${TIMESTAMP}.prof" 2>/dev/null || echo "")
    
    if [[ -z "${profiles}" ]]; then
        echo "No profiles generated"
        return 0
    fi
    
    local analysis_file="${PROFILE_DIR}/analysis_${TIMESTAMP}.txt"
    echo "Profile Analysis - $(date)" > "${analysis_file}"
    echo "=================================" >> "${analysis_file}"
    echo >> "${analysis_file}"
    
    while IFS= read -r profile; do
        local profile_name
        profile_name=$(basename "${profile}")
        echo "Analyzing ${profile_name}..."
        
        echo "Profile: ${profile_name}" >> "${analysis_file}"
        echo "------------------------" >> "${analysis_file}"
        
        # Generate top functions for each profile type
        if [[ "${profile_name}" =~ cpu ]]; then
            echo "Top CPU consuming functions:" >> "${analysis_file}"
            go tool pprof -top -cum "${profile}" 2>/dev/null | head -15 >> "${analysis_file}" || echo "Analysis failed" >> "${analysis_file}"
        elif [[ "${profile_name}" =~ mem ]]; then
            echo "Top memory allocating functions:" >> "${analysis_file}"
            go tool pprof -top -cum "${profile}" 2>/dev/null | head -15 >> "${analysis_file}" || echo "Analysis failed" >> "${analysis_file}"
        fi
        
        echo >> "${analysis_file}"
        
    done <<< "${profiles}"
    
    if [[ ${VERBOSE} -eq 1 ]]; then
        echo
        echo "Profile analysis:"
        cat "${analysis_file}"
    fi
    
    echo "✅ Analysis saved to: ${analysis_file}"
}

run_performance_tests()
{
    echo "Running performance regression tests..."
    
    # Create simple performance test if none exist
    local perf_test_dir="${PROJECT_ROOT}/cmd/triple-enhance-migrate"
    if [[ -d "${perf_test_dir}" ]] && [[ ! -f "${perf_test_dir}/perf_test.go" ]]; then
        cat > "${perf_test_dir}/perf_test.go" << 'EOF'
package main

import (
    "testing"
)

// Benchmark metadata extraction
func BenchmarkExtractBookMetadata(b *testing.B) {
    book := &BookMetadata{
        Name: "Test Book: Advanced Algorithms and Data Structures",
        Content: struct {
            OCR     string `json:"ocr"`
            PDFText string `json:"pdf_text"`
        }{
            OCR:     "This is sample OCR content with algorithms and data structures",
            PDFText: "Chapter 1: Introduction to algorithms and complexity analysis",
        },
    }
    
    b.ResetTimer()
    for i := 0; i < b.N; i++ {
        _ = extractBookMetadata(book)
    }
}

// Benchmark prompt generation
func BenchmarkGenerateEnhancementPrompt(b *testing.B) {
    book := BookMetadata{
        Title:   "Advanced Algorithms and Data Structures",
        Author:  "Test Author",
        Subject: "algorithms",
    }
    
    b.ResetTimer()
    for i := 0; i < b.N; i++ {
        _ = generateEnhancementPrompt(book, "gemini")
    }
}

// Benchmark text processing functions
func BenchmarkCleanTitle(b *testing.B) {
    title := "Advanced_Algorithms_and_Data_Structures_by_Author_abc123.pdf"
    
    b.ResetTimer()
    for i := 0; i < b.N; i++ {
        _ = cleanTitle(title)
    }
}

func BenchmarkClassifySubject(b *testing.B) {
    title := "Advanced Algorithms and Data Structures"
    content := "This book covers sorting algorithms, graph traversal, dynamic programming, and complexity analysis"
    
    b.ResetTimer()
    for i := 0; i < b.N; i++ {
        _ = classifySubject(title, content)
    }
}

func BenchmarkEstimateTokenCount(b *testing.B) {
    text := "This is a sample text that we use to estimate token count for various AI providers and their different models with varying context windows"
    
    b.ResetTimer()
    for i := 0; i < b.N; i++ {
        _ = estimateTokenCount(text)
    }
}
EOF
        echo "✅ Created performance tests"
    fi
    
    # Run performance-specific tests
    local perf_output="${PROFILE_DIR}/performance_${TIMESTAMP}.txt"
    
    if go test -run=XXX -bench=. -benchtime=5s ./... > "${perf_output}" 2>&1; then
        echo "✅ Performance tests completed"
        
        # Extract key metrics
        echo
        echo "Performance metrics:"
        grep -E "(Benchmark|ns/op|B/op|allocs/op)" "${perf_output}" | head -10 || echo "No performance metrics found"
        
    else
        echo "❌ Performance tests failed"
        if [[ ${VERBOSE} -eq 1 ]]; then
            cat "${perf_output}"
        fi
    fi
}

generate_summary()
{
    echo
    echo "========================================="
    echo "         PROFILING SUMMARY"
    echo "========================================="
    
    # List generated files
    local generated_files
    generated_files=$(find "${PROFILE_DIR}" -name "*_${TIMESTAMP}.*" 2>/dev/null | sort || echo "")
    
    if [[ -n "${generated_files}" ]]; then
        echo "Generated files:"
        while IFS= read -r file; do
            local file_size
            file_size=$(du -h "${file}" 2>/dev/null | cut -f1 || echo "unknown")
            echo "  📁 $(basename "${file}") (${file_size})"
        done <<< "${generated_files}"
        
        echo
        echo "Profile analysis commands:"
        while IFS= read -r file; do
            if [[ "${file}" =~ \.prof$ ]]; then
                echo "  go tool pprof ${file}"
            fi
        done <<< "${generated_files}"
        
        echo
        echo "Web interface:"
        local first_profile
        first_profile=$(echo "${generated_files}" | grep '\.prof$' | head -1 || echo "")
        if [[ -n "${first_profile}" ]]; then
            echo "  go tool pprof -http=:8080 ${first_profile}"
        fi
        
    else
        echo "No profile files generated"
    fi
    
    echo "========================================="
}

main()
{
    parse_args "$@"
    setup_environment
    
    echo "Starting Go profiling and performance analysis..."
    echo
    
    # Run different types of profiling
    if go list ./... >/dev/null 2>&1; then
        run_benchmarks
        echo
        
        run_unit_test_profiling
        echo
        
        run_performance_tests
        echo
        
        generate_profile_analysis
        
    else
        echo "No Go modules found, skipping profiling"
        exit 0
    fi
    
    generate_summary
    echo "Profiling completed! 🚀"
}

# Run main function
main "$@"