# Comprehensive BASH Code Guidelines for LLMs

**FOLLOW THESE RULES STRICTLY** - These guidelines ensure robust, maintainable scripts that handle edge cases gracefully and pass all linter checks.

## 1. Script Initialization and Safety

### Strict Mode Settings
```bash
#!/bin/bash
set -u  # Exit on undefined variables
# Never use: set -e (can mask important errors)
```

### Error Handling Philosophy
- **NEVER redirect to `/dev/null`** - This hides critical debugging information
- **NEVER suppress error output** - Always capture and handle errors explicitly
- Use proper exit code checking instead of hiding failures

```bash
# ❌ BAD - Hides errors
command 2>/dev/null
value=$(yq -r "$key" "$CONFIG_FILE" 2>/dev/null)
if ! command -v "$dep" >/dev/null 2>&1; then

# ✅ GOOD - Captures errors for debugging
value=$(yq -r "$key" "$CONFIG_FILE")
if ! command -v "$dep"; then
```

## 2. Variable Management

### Declaration and Scope Rules
- **Always declare variables before assignment** to prevent undefined variable errors
- Use `declare` at global scope and `local` inside functions
- **Global variables must contain "GLOBAL" in their name** for clarity
- **Initialize all variables explicitly** - no implicit empty values
- **Declare and assign on separate lines** for better error tracking
- **ALL variables must be declared at the top** - global variables at the top of the script, local variables at the top of functions

```bash
# ✅ GOOD - Global variables at top of script
declare INPUT_GLOBAL=""
declare OUTPUT_GLOBAL=""
declare -r CONFIG_FILE_GLOBAL="/path/to/config"
declare -r MAX_RETRIES_GLOBAL=3

# ✅ GOOD - Function with all local variables at top
function process_data() {
    # ALL local variables declared at the top of function
    local exit_code=""
    local jq_output=""
    local jq_status_exit=1
    local result=""
    local retry_count=0
    
    # Function logic starts after all variable declarations
    jq_output=$(echo "$full_response" | head -1 | jq -e '.choices[0].delta' 2>&1)
    jq_status_exit="$?"
    
    if [[ -n "$jq_output" && "$jq_status_exit" -eq 0 ]]; then
        echo "Valid JSON response"
    fi
}

# ❌ AVOID - Variables scattered throughout
function bad_example() {
    local first_var=""  # Variable declaration
    
    some_command
    
    local second_var=""  # BAD: Variable declared in middle of function
    
    more_logic
    
    local third_var=""   # BAD: Another variable declared later
}

# ❌ AVOID
SOME_VAR=$(...) # Unclear scope and purpose
jq_check_output=$(echo "$full_response" | head -1 | jq -e '.choices[0].delta' 2>&1)
jq_check_exit="$?"
if [[ $jq_check_exit -eq 0 ]]; then  # Redundant check without output validation
```

### Variable Naming and Usage
- **All variables must be declared at the top** of their scope (script or function)
- Sort variable declarations when possible, preferably alphabetically or by logical grouping
- Quote all variables, especially `"$?"` when assigning exit codes
- Use meaningful, descriptive names

```bash
# ✅ GOOD - All variables at top, sorted logically
local attempt_number=0
local iteration_count=""
local pdf_basename=""
local result=""
local temp_file=""

# Function logic follows variable declarations
# ... rest of function implementation

# ❌ AVOID - Variables declared throughout function
function bad_function() {
    local i=0  # Variable here
    
    some_logic
    
    local x=""  # BAD: Variable in middle
    
    more_logic
    
    local tmp=""  # BAD: Variable at end
}
```

## 3. Control Flow and Conditionals

### Explicit Control Structures
- **Use explicit `if/then/fi` blocks** for all conditionals - never one-liners
- **Ensure all control blocks are properly closed** (`if/fi`, `while/done`, `for/done`)
- **Capture command output explicitly before testing conditions**
- **Always assign exit codes to variables** instead of using `$?` directly
- **Avoid using `$?` when possible** - prefer direct command testing

```bash
# ✅ GOOD - Explicit output capture and testing
local output=""
local exit_code=""
output=$(some_command)
exit_code="$?"

if [[ "$exit_code" -eq 0 ]]; then
    echo "Success: $output"
fi

# ✅ ALSO GOOD - Direct command testing when output not needed
# Avoid doing this for long commands that with many pipes
if some_command; then   
    echo "Command succeeded"
fi

# ❌ AVOID
if some_command; then process; fi  # One-liner
if (( i++ )); then                 # Compound arithmetic in condition
if [[ $? -eq 0 ]]; then           # Direct $? usage
```

### Arithmetic and Comparisons
- Use `i=$((i + 1))` instead of `((i++))`
- **Prefer `[[ ]]` over `[ ]`** for test conditions
- **Prefer `[[ $var -eq 0 ]]` over `((var == 0))`** for arithmetic operations

```bash
# ✅ GOOD
for iteration_count in $(seq 1 "$MAX_RETRIES_GLOBAL"); do
    attempt_number=$((attempt_number + 1))
    if [[ "$attempt_number" -eq "$MAX_RETRIES_GLOBAL" ]]; then
        break
    fi
done

# ❌ AVOID
for ((i++; i < max; i++)); do  # Non-portable and unclear
if ((var == 0)); then          # Less reliable than [[ ]]
```

## 4. File Operations and I/O

### Safe File Operations
- **Use atomic file operations** (`mv`, `flock`) to prevent race conditions in parallel processing
- **Prefer `rsync` over `cp`** for file copying operations
- **Use `cmd < file` instead of `cat file | cmd`** (avoid useless cat)
- Implement solid but efficient retry logic for critical operations

```bash
# ✅ GOOD - Atomic and efficient
rsync -av "$source" "$destination"

# Process files efficiently
while read -r line; do
    process_line "$line"
done < "$input_file"

# Create atomic file updates
temp_file=$(mktemp)
process_data > "$temp_file"
mv "$temp_file" "$final_file"

# ❌ AVOID
cp "$source" "$destination"  # Less robust than rsync
cat "$input_file" | while read line; do  # Useless cat
```

### printf Best Practices
- **Never use variables directly in printf format strings**
- **Always use `printf '%s' "$VARIABLE"`** for string output

```bash
# ✅ GOOD
printf '%s\n' "$message"
printf '%d files processed\n' "$count"

# ❌ AVOID
printf "$message"  # Dangerous - treats variable as format string
```

## 5. Configuration Management

### Configuration Variables
- **Configuration file variables should be readonly** (`declare -r`)
- **API keys and sensitive data must be readonly**
- **No hardcoded values** - use configuration variables
- **Everything should be parameterized** and moved to project.toml

```bash
# ✅ GOOD - Readonly configuration
declare -r API_KEY_GLOBAL="$1"
declare -r CONFIG_FILE_GLOBAL="/etc/myapp/config"
declare -r MAX_RETRIES_GLOBAL=3
declare -r DPI_GLOBAL=600

# ❌ AVOID
api_key="hardcoded-key-123"  # Not readonly, hardcoded
timeout=30                   # Hardcoded magic number
dpi=600                      # Should be configurable
```

## 6. Directory Structure Standards

### Standard Directory Layout
- `INPUT_GLOBAL`: Location where raw PDF files exist
- `OUTPUT_GLOBAL`: Location where all produced artifacts are stored
- **All artifacts saved under**: `$OUTPUT_GLOBAL/$PDF_NAME/<artifact_type>/`
- **Maintain consistent directory structure** across all operations

```bash
# ✅ GOOD - Consistent structure
for pdf_file in "$INPUT_GLOBAL"/*.pdf; do
    pdf_basename=$(basename "$pdf_file" .pdf)
    output_dir="$OUTPUT_GLOBAL/$pdf_basename"
    
    # Create structured output directories
    local mkdir_result=""
    local mkdir_exit=""
    mkdir_result=$(mkdir -p "$output_dir/extracted" "$output_dir/processed" 2>&1)
    mkdir_exit="$?"
    
    if [[ "$mkdir_exit" -ne 0 ]]; then
        echo "Failed to create output directories: $mkdir_result"
        continue
    fi
done
```

## 7. Error Handling and Debugging

### Debugging Best Practices
- **Enable strict error checking** with `set -u` to catch unbound variables
- **Clean up unused variables** and maintain detailed comments
- **Avoid unreachable code** or redundant commands
- Use `grep -q` for silent boolean checks

```bash
# ✅ GOOD - Comprehensive error handling
function critical_operation() {
    local result=""
    local exit_code=""
    
    result=$(critical_command 2>&1)
    exit_code="$?"
    
    if [[ "$exit_code" -ne 0 ]]; then
        echo "Operation failed with exit code $exit_code: $result" >&2
        return "$exit_code"
    fi
    
    echo "$result"
}

# ✅ GOOD - Silent boolean check
if grep -q "pattern" "$file"; then
    echo "Pattern found"
fi
```

## 8. Code Quality and Maintenance

### Code Organization
- **Keep code concise, clear, and self-documented**
- **Comments should explain intent, not just mechanics**
- **Do more with less** - avoid adding code without clear purpose
- **Lint all scripts with `shellcheck`** for correctness
- **Update comments when code changes** to maintain consistency

```bash
# ✅ GOOD - Self-documenting with clear intent and proper variable organization
# Process each PDF file in the input directory and generate artifacts
# This function handles the complete pipeline from PDF to processed output
function process_pdf_pipeline() {
    # ALL local variables declared at the top - required pattern
    local pdf_file="$1"
    local pdf_basename=""
    local output_dir=""
    local mkdir_result=""
    local mkdir_exit=""
    
    # Function logic starts after all variable declarations
    pdf_basename=$(basename "$pdf_file" .pdf)
    output_dir="$OUTPUT_GLOBAL/$pdf_basename"
    
    # Create output structure for this PDF's artifacts
    # Each PDF gets its own subdirectory with organized artifact types
    mkdir_result=$(mkdir -p "$output_dir/extracted" "$output_dir/processed" 2>&1)
    mkdir_exit="$?"
    
    if [[ "$mkdir_exit" -ne 0 ]]; then
        echo "Failed to create output directories for $pdf_basename: $mkdir_result" >&2
        return 1
    fi
    
    echo "Successfully prepared directories for $pdf_basename"
}
```

## 9. API and External Commands

### External Command Handling
- **Avoid mixing different API calls** in the same function
- **Capture both output and exit codes** for external commands
- **Implement proper error handling** for all external dependencies
- **Always consult the latest documentation** for APIs

```bash
# ✅ GOOD - Proper external command handling with variables at top
function call_api() {
    # ALL local variables at the top of function
    local api_response=""
    local api_exit_code=""
    local retry_count=0
    
    # Function logic after variable declarations
    while [[ "$retry_count" -lt "$MAX_RETRIES_GLOBAL" ]]; do
        api_response=$(curl -s -w "%{http_code}" "$API_ENDPOINT" 2>&1)
        api_exit_code="$?"
        
        if [[ "$api_exit_code" -eq 0 ]]; then
            echo "$api_response"
            return 0
        fi
        
        retry_count=$((retry_count + 1))
        sleep "$RETRY_DELAY_GLOBAL"
    done
    
    echo "API call failed after $MAX_RETRIES_GLOBAL attempts" >&2
    return 1
}
```

## 10. Summary Principles

### Core Design Philosophy
1. **Explicit over implicit** - declare intentions clearly
2. **Safe by default** - use strict error checking  
3. **Self-documenting** - code should explain itself
4. **Atomic operations** - prevent race conditions
5. **No hidden failures** - never suppress error output
6. **Consistent structure** - follow established patterns
7. **Maintainable** - keep comments current with code changes
8. **Parameterized** - avoid hardcoded values
9. **Debuggable** - provide clear error messages and logging
10. **Linter-compliant** - pass all shellcheck validations

### Quick Reference Checklist
- [ ] All variables declared before use
- [ ] **Global variables at top of script, local variables at top of functions**
- [ ] Global variables contain "GLOBAL" in name
- [ ] No redirection to `/dev/null`
- [ ] Exit codes captured in variables
- [ ] All control blocks properly closed
- [ ] Configuration values are readonly
- [ ] File operations are atomic
- [ ] Error messages are descriptive
- [ ] Code passes shellcheck validation
- [ ] Comments explain intent, not mechanics

These guidelines ensure robust, maintainable BASH scripts that handle edge cases gracefully and provide clear debugging information when issues arise.
