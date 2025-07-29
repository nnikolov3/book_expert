# BASH Code Guidelines for LLMs

## Variable Management
- **Always declare variables before assignment** to prevent undefined variable errors
- Use `declare` at global scope and `local` inside functions
- Global variables must contain "GLOBAL" in their name for clarity
- Initialize all variables explicitly - no implicit empty values
- Declare and assign each variable on separate lines for clarity
- Sort variable declarations when possible, preferably at the top of functions/scripts

```bash
# Good
declare INPUT_GLOBAL=""
declare -r CONFIG_FILE_GLOBAL="/path/to/config"
local output=""
local exit_code=""

# Avoid
SOME_VAR=$(...) # unclear scope and purpose
```

## Control Flow and Structure
- Use explicit `if/then/fi` blocks for all conditionals - never one-liners
- Ensure all control blocks (`if/fi`, `while/done`, `for/done`) are properly closed
- Capture command output explicitly before testing conditions
- Always assign exit codes to variables instead of using `$?` directly

```bash
# Good
output=$(some_command)
exit_code="$?"
if [[ "$exit_code" -eq 0 ]]; then
    echo "Success: $output"
fi

# Avoid
if some_command; then  # Don't test commands directly
if (( i++ )); then     # Don't use compound arithmetic
if [[ $? -eq 0 ]]; then # Don't use $? directly
```

## File Operations and Safety
- Use **atomic file operations** (`mv`, `flock`) to prevent race conditions in parallel processing
- Prefer `rsync` over `cp` for file copying operations
- Use `cmd < file` instead of `useless cat | cmd`
- Implement solid but efficient retry logic for critical operations

```bash
# Good
rsync -av "$source" "$destination"
while read -r line; do
    process_line "$line"
done < "$input_file"

# Avoid
cp "$source" "$destination"
cat "$input_file" | while read line; do
```

## Error Handling and Debugging
- Enable strict error checking with `set -u` to catch unbound variables
- **Never redirect to `/dev/null`** - redirection hides potential issues
- Quote all variables, especially `"$?"` when assigning exit codes
- Clean up unused variables and maintain detailed comments
- Avoid unreachable code or redundant commands

```bash
# Good
set -u
command_output=$(critical_command 2>&1)
command_exit="$?"
if [[ "$command_exit" -ne 0 ]]; then
    echo "Command failed with exit code: $command_exit"
    echo "Output: $command_output"
fi

# Avoid
critical_command 2>/dev/null  # Hides errors
some_command 2>>"$LOG_FILE"  # Inconsistent logging pattern
```

## Configuration and Constants
- Configuration file variables should be **readonly** (`declare -r`)
- API keys and sensitive data must be readonly
- No hardcoded values - use configuration variables
- Everything should be parameterized and configurable

```bash
# Good
declare -r API_KEY_GLOBAL="$1"
declare -r CONFIG_FILE_GLOBAL="/etc/myapp/config"
declare -r MAX_RETRIES_GLOBAL=3

# Avoid
api_key="hardcoded-key-123"  # Not readonly, hardcoded
timeout=30                   # Hardcoded magic number
```

## Code Quality and Maintenance
- Keep code **concise, clear, and self-documented**
- Comments should explain intent, not just mechanics
- **Do more with less** - avoid adding code without clear purpose
- Use `grep -q` for silent boolean checks
- Lint all scripts with `shellcheck` for correctness
- Update comments when code changes to maintain consistency

```bash
# Good - self-documenting with clear intent
# Process each PDF file in the input directory and generate artifacts
for pdf_file in "$INPUT_GLOBAL"/*.pdf; do
    pdf_basename=$(basename "$pdf_file" .pdf)
    output_dir="$OUTPUT_GLOBAL/$pdf_basename"
    
    # Create output structure for this PDF's artifacts
    mkdir_result=$(mkdir -p "$output_dir/extracted" "$output_dir/processed" 2>&1)
    mkdir_exit="$?"
    
    if [[ "$mkdir_exit" -ne 0 ]]; then
        echo "Failed to create output directories: $mkdir_result"
        continue
    fi
done
```

## Directory Structure Standards
- `INPUT_GLOBAL`: Location where raw PDF files exist
- `OUTPUT_GLOBAL`: Location where all produced artifacts are stored
- All artifacts saved under: `$OUTPUT_GLOBAL/$PDF_NAME/<artifact_type>/`
- Maintain consistent directory structure across all operations

## Arithmetic and Loops
- Use `i=$((i + 1))` instead of `((i++))`
- Prefer `[[ ]]` over `[ ]` for test conditions
- Use meaningful variable names in loops

```bash
# Good
for iteration_count in $(seq 1 "$MAX_RETRIES_GLOBAL"); do
    attempt_number=$((attempt_number + 1))
done

# Avoid
for ((i++; i < max; i++)); do  # Unclear and non-portable
```

## API and External Commands
- Avoid mixing different API calls in the same function
- Capture both output and exit codes for external commands
- Implement proper error handling for all external dependencies
- Always consult the latest documentation for the APIs.

## Summary Principles
1. **Explicit over implicit** - declare intentions clearly
2. **Safe by default** - use strict error checking
3. **Self-documenting** - code should explain itself
4. **Atomic operations** - prevent race conditions
5. **No hidden failures** - never suppress error output
6. **Consistent structure** - follow established patterns
7. **Maintainable** - keep comments current with code changes

Remember: These guidelines ensure robust, maintainable BASH scripts that handle edge cases gracefully and provide clear debugging information when issues arise.
