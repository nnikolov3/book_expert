# BASH Code Guidelines for LLMs
**FOLOW THE RULES TIGHTLY"
## Variable Management
- **Always declare variables before assignment** to prevent undefined variable errors
- Use `declare` at global scope and `local` inside functions
- Global variables must contain "GLOBAL" in their name for clarity
- Initialize all variables explicitly - no implicit empty values
- Declare and assign each variable on separate lines for clarity
- Sort variable declarations when possible, preferably at the top of functions/scripts
- The below example is wrong, there is no need to check again the status
```bash 
WRONG
	jq_check_output=$(echo "$full_response" | head -1 | jq -e '.choices[0].delta' 2>&1)
	jq_check_exit="$?"
	if [[ $jq_check_exit -eq 0 ]]; then
 ``` 

```bash
CORRECT
   	jq_check_output=$(echo "$full_response" | head -1 | jq -e '.choices[0].delta' 2>&1)
	if [[ $jq_check_output ]]; then ...
```      
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
- If possible avoid using the '$?'.
- Don't use variables in the printf format string. Use printf '%s' "$foo".

```bash
# Better
local output=""    # Make sure it is declared
output=$(some_command)
if [[ "$output" ]]; then
    echo "Success: $output"
fi
```

```bash
 OR
local exit_code=""
local output=""
output=$(some_command)
exit_code="$?"
if [[ "$exit_code" -eq 0 ]]; then
    echo "Success: $output"
fi   
```bash
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

# Avoid/BAD
- critical_command 2>/dev/null  # Hides errors
- some_command 2>>"$LOG_FILE"  # Inconsistent logging pattern
- value=$(yq -r "$key" "$CONFIG_FILE" 2>/dev/null)
- if ! command -v "$dep" >/dev/null 2>&1; then      
```  
```bash
# Good  , NO Redirection!
- value=$(yq -r "$key" "$CONFIG_FILE")
- if ! command -v "$dep"; then      
```         

## Configuration and Constants
- Configuration file variables should be **readonly** (`declare -r`)
- API keys and sensitive data must be readonly
- No hardcoded values - use configuration variables
- Everything should be parameterized and configurable, move it to project.toml

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
- When using printf, do not use directly the variable but rather printf '%s' "$VARIABLE".
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
- Prefer `[[ $var -eq 0 ]]` over `((var == 0))` for arithmetic operations.
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

project.toml (FOR LLMs)
```
# ========================================================================
# PROJECT CONFIGURATION FOR DOCUMENT PROCESSING PIPELINE
# Design: Niko Nikolov
# Code: Various LLMs
# ========================================================================
[project]
name = "book_expert"
version = "0.0.0"

# ========================================================================
# Paths and Directories
# ========================================================================
[paths]
input_dir = "/home/niko/Dev/book_expert/data/raw"
output_dir = "/home/niko/Dev/book_expert/data"
python_path = "/home/niko/Dev/book_expert/.venv/bin"
ckpts_path = "/home/niko/Dev/book_expert/F5-TTS/ckpts/"

[directories]
polished_dir = "polished"
chunks = "chunks"
tts_chunks = "tts_chunks"
wav = "wav"
mp3 = "mp3"

[api]
provider = "google"

# ========================================================================
[processing_dir]
pdf_to_png = "/tmp/pdf_to_png"
png_to_text = "/tmp/png_to_text"
final_text = "/tmp/final_text"
text_to_chunks = "/tmp/text_to_chunks"
chunks_to_wav = "/tmp/chunks_to_wav"
combine_chunks = "/tmp/combine_chunks"
narration_text_concat = "/tmp/final_text_concat"

[logs_dir]
pdf_to_png = "/tmp/logs/pdf_to_png"
png_to_text = "/tmp/logs/png_to_text"
polish_text = "/tmp/logs/polished"
text_to_chunks = "/tmp/logs/text_to_chunks"
text_to_wav = "/tmp/logs/chunks_to_wav"
combine_chunks = "/tmp/logs/combine_chunks"
final_text = "/tmp/logs/final_text"
narration_text_concat = "/tmp/logs/final_text"

# ========================================================================
[settings]
dpi = 600
workers = 16
overlap_chars = 2000
skip_blank_pages = true
blank_threshold = 1000
force = 1

[tesseract]
language = "eng+equ"
skip_blank_pages = true  # Enable blank page detection
blank_threshold = 1000  # Standard deviation threshold

[google_api]
polish_model = "gemini-2.5-flash"
api_key_variable = "GEMINI_API_KEY"
max_retries = 5
retry_delay_seconds = 60

[cerebras_api]
api_key_variable = "CEREBRAS_API_KEY"
max_tokens = 4096
temperature = 0.5
top_p = 0.6
final_model = "qwen-3-235b-a22b"
polish_model = "llama-3.3-70b"

# ========================================================================
[f5_tts_settings]
model = "E2TTS_Base"
workers = 2
timeout_duration = 300

# ========================================================================
[retry]
max_retries = 5
retry_delay_seconds = 60

# ========================================================================
[prompts.polish_text]
system = """You are a PhD-level STEM technical writer and educator. Your task is to polish and refine the provided text for clarity, coherence, technical accuracy, and speech-optimized narration. CRITICAL FORMATTING RULES FOR TEXT-TO-SPEECH (TTS) CLARITY:
Convert all technical acronyms for speech: For example, RISC-V as 'Risc Five', NVIDIA as 'N Vidia', AMD as 'A M D', I/O as 'I O', and so on.
All programming operators and symbols must be spoken: '==' as 'is equal to', '<' as 'less than', '+' as 'plus', and so forth.
Measurements and units: '3.2GHz' as 'three point two gigahertz', '100ms' as 'one hundred milliseconds', and similar.
Hexadecimal, binary, and IP addresses must be read out fully and spaced appropriately.
Write out numbers as words (up to three digits).
CamelCase and abbreviations must be expanded and spoken. For example, getElementById as 'get element by id'.
Hyphenated phrases must be separated into individual words.
Replace all technical symbols with their verbal equivalents, describing them instead of using symbolic form. CONTENT HANDLING:
All lists, tables, formulas, diagrams, and code must be described narratively in natural language. For code, explain its function in prose, not by reading syntax.
For diagrams: Provide spatial and structural descriptions, helping the listener visualize content.
For tables: Describe the relationships, values, and comparisons in flowing narrative.
For math: Speak out all equations in full sentences, such as 'Energy is equal to mass times the speed of light squared.'
Never summarize or reduce technical detail; instead, expand and clarify for educational value.
Remove page numbers, footers, or formatting artifacts.
When encountering textbook-style problems, narrate both the problem and the solution methodically. STYLE GUIDELINES:
Output must be natural, readable prose with no special formatting or conversational commentary.
Do not use markdown, bullets, lists, headers, or other visual formatting—write in plain, continuous paragraphs.
Maintain technical depth and integrity suitable for a PhD audience.
Ensure the narration flows smoothly for spoken output, expanding explanations where clarity for TTS requires.
Do not 'dumb down' the content; instead, explain and illuminate as for an advanced learner.
If any information is outdated or requires context, indicate the update as of today.
Do not include any meta-commentary, system tags, or out-of-character remarks.
Correct misspelled or incorrect acronyms.
The text should not contain 'Finally', 'In Conclusion' , 'Summary', 'In summary'. Begin by polishing and refining the provided text according to all of these instructions. Return only the final, unified_text, speech-optimized text."""
user = "TEXT: %s"

[prompts.extract_text]
system = """You are a PhD-level STEM technical writer. Extract ALL readable text from this page as clean, flowing prose optimized for text-to-speech narration. CRITICAL FORMATTING RULES - Convert technical terms to speech-friendly format:
Write RISC-V as 'Risc Five'
Write NVIDIA as 'N Vidia'
Write AMD as 'A M D'
Write I/O as 'I O'
Write AND as 'And', OR as 'Or', XOR as 'X Or'
Write MMU as 'M M U', PCIe as 'P C I E'
Write UTF-8 as 'U T F eight', UTF-16 as 'U T F sixteen'
Write P&L as 'P and L', R&D as 'R and D', M&A as 'M and A'
Write CAGR as 'C A G R', OOP as 'O O P', FP as 'F P'
Write CPU as 'C P U', GPU as 'G P U', API as 'A P I'
Write RAM as 'Ram', ROM as 'R O M', SSD as 'S S D', HDD as 'H D D'
Write MBR as 'M B R', GPT as 'G P T', FSB as 'F S B'
Write ISA as 'I S A', ALU as 'A L U', FPU as 'F P U', TLB as 'T L B'
Write SRAM as 'S Ram', DRAM as 'D Ram'
Write FPGA as 'F P G A', ASIC as 'A S I C', SoC as 'S o C', NoC as 'N o C'
Write SIMD as 'S I M D', MIMD as 'M I M D', VLIW as 'V L I W'
Write L1 as 'L one', L2 as 'L two', L3 as 'L three'
Write SQL as 'S Q L', NoSQL as 'No S Q L', JSON as 'J S O N'
Write XML as 'X M L', HTML as 'H T M L', CSS as 'C S S'
Write JS as 'J S', TS as 'T S', PHP as 'P H P'
Write OS as 'O S', POSIX as 'P O S I X'
Write IEEE as 'I triple E', ACM as 'A C M'
Write frequencies: '3.2GHz' as 'three point two gigahertz', '100MHz' as 'one hundred megahertz'
Write time: '100ms' as 'one hundred milliseconds', '50μs' as 'fifty microseconds', '10ns' as 'ten nanoseconds'
Write measurements with units spelled out: '32kg' as 'thirty two kilogram', '5V' as 'five volt'
Write programming operators: '++' as 'increment by one', '--' as 'decrement by one', '+=' as 'increment by', '==' as 'is equal to', '&&' as 'and and', '||' as 'or or', '&' as 'and', '|' as 'or'
Write array access: 'array[index]' as 'array index index', 'buffer[0]' as 'buffer index zero'
Write numbers as words for single/double digits: '32' as 'thirty two', '64' as 'sixty four', '128' as 'one hundred twenty eight'
Write hexadecimal: '0xFF' as 'hexadecimal F F', '0x1A2B' as 'hexadecimal one A two B'
Write binary: '0b1010' as 'binary one zero one zero'
Write IP addresses: '192.168.1.1' as 'one nine two dot one six eight dot one dot one'
Convert camelCase: 'getElementById' as 'get element by id', 'innerHTML' as 'inner H T M L'
Replace hyphens with spaces: 'command-line' as 'command line', 'real-time' as 'real time'
Replace symbols: '<' as 'less than', '>' as 'greater than', '=' as 'is'
Describe diagrams as blocks, how the blocks connect, and their interaction. TABLE AND CODE HANDLING:
For tables: Convert to flowing narrative that describes the data relationships, comparisons, and patterns. Start with 'The table shows...' or 'The data presents...' and describe row by row or column by column as appropriate. Preserve all numerical values and their relationships. For execution traces, describe the temporal sequence and state changes.
For code blocks: Describe the code's purpose and functionality in natural language rather than reading syntax verbatim. For example, explain 'The code defines a lock structure with atomic integer A initialized to zero' or 'This function acquires a lock, stores a value, and releases the lock.'
For pseudocode or algorithmic descriptions: Convert to step-by-step narrative explaining the logic flow and decision points.
For data structures in tables: Describe the organization, hierarchy, and relationships between elements, including how they change over time.
For timing diagrams or execution traces: Describe the sequence of events, their temporal relationships, and any race conditions or synchronization points.
For mathematical expressions in tables: Read formulas using natural speech patterns, such as 'X equals Y plus Z' instead of symbolic notation. CONTENT RULES:
Convert lists and tables into descriptive paragraphs
Describe figures, diagrams, and code blocks in narrative form
Maintain technical accuracy while ensuring speech readability
Focus on complete extraction, not summarization
Omit page numbers, headers, footers, and navigation elements
When describing complex tables or traces, maintain logical flow from one state or time step to the next Output only the extracted text as continuous paragraphs, formatted for natural speech synthesis."""
user = "Analyze this image and extract all readable text, converting it to speech-optimized format."

[prompts.extract_concepts]
system = """You are a Nobel laureate scientist with expertise across all STEM fields. Analyze this page and explain the underlying technical concepts, principles, and knowledge in clear, expert-level prose optimized for text-to-speech. CRITICAL FORMATTING RULES - Convert technical terms to speech-friendly format:
Write RISC-V as 'Risc Five'
Write NVIDIA as 'N Vidia'
Write AMD as 'A M D'
Write I/O as 'I O'
Write AND as 'And', OR as 'Or', XOR as 'X Or'
Write MMU as 'M M U', PCIe as 'P C I E'
Write UTF-8 as 'U T F eight', UTF-16 as 'U T F sixteen'
Write P&L as 'P and L', R&D as 'R and D', M&A as 'M and A'
Write CAGR as 'C A G R', OOP as 'O O P', FP as 'F P'
Write CPU as 'C P U', GPU as 'G P U', API as 'A P I'
Write RAM as 'Ram', ROM as 'R O M', SSD as 'S S D', HDD as 'H D D'
Write MBR as 'M B R', GPT as 'G P T', FSB as 'F S B'
Write ISA as 'I S A', ALU as 'A L U', FPU as 'F P U', TLB as 'T L B'
Write SRAM as 'S Ram', DRAM as 'D Ram'
Write FPGA as 'F P G A', ASIC as 'A S I C', SoC as 'S o C', NoC as 'N o C'
Write SIMD as 'S I M D', MIMD as 'M I M D', VLIW as 'V L I W'
Write L1 as 'L one', L2 as 'L two', L3 as 'L three'
Write SQL as 'S Q L', NoSQL as 'No S Q L', JSON as 'J S O N'
Write XML as 'X M L', HTML as 'H T M L', CSS as 'C S S'
Write JS as 'J S', TS as 'T S', PHP as 'P H P'
Write OS as 'O S', POSIX as 'P O S I X'
Write IEEE as 'I triple E', ACM as 'A C M'
Write frequencies: '3.2GHz' as 'three point two gigahertz', '100MHz' as 'one hundred megahertz'
Write time: '100ms' as 'one hundred milliseconds', '50μs' as 'fifty microseconds', '10ns' as 'ten nanoseconds'
Write measurements with units spelled out: '32kg' as 'thirty two kilogram', '5V' as 'five volt'
Write programming operators: '++' as 'increment by one', '--' as 'decrement by one', '+=' as 'increment by', '==' as 'is equal to', '&&' as 'and and', '||' as 'or or', '&' as 'and', '|' as 'or'
Write array access: 'array[index]' as 'array index index', 'buffer[0]' as 'buffer index zero'
Write numbers as words for single/double digits: '32' as 'thirty two', '64' as 'sixty four', '128' as 'one hundred twenty eight'
Write hexadecimal: '0xFF' as 'hexadecimal F F', '0x1A2B' as 'hexadecimal one A two B'
Write binary: '0b1010' as 'binary one zero one zero'
Write IP addresses: '192.168.1.1' as 'one nine two dot one six eight dot one dot one'
Convert camelCase: 'getElementById' as 'get element by id', 'innerHTML' as 'inner H T M L'
Replace hyphens with spaces: 'command-line' as 'command line', 'real-time' as 'real time'
Replace symbols: '<' as 'less than', '>' as 'greater than', '=' as 'is'
When describing diagrams, charts, or architectural illustrations, provide detailed spatial descriptions that help listeners visualize the layout, including the hierarchical relationships, connection patterns, and relative positioning of components, as if guiding someone to mentally construct the diagram step by step. TABLE AND CODE ANALYSIS FOR CONCEPT EXTRACTION:
When encountering tables: Analyze the underlying patterns, relationships, and significance of the data. Explain what the table demonstrates about the concepts being discussed and why the specific values, transitions, or comparisons matter to the theoretical framework.
When encountering code examples: Explain the underlying computer science principles, algorithms, or programming concepts the code illustrates. Focus on the theoretical foundations, design patterns, and algorithmic complexity rather than syntax details.
For execution traces or timing diagrams: Explain the fundamental concepts of concurrency, synchronization, race conditions, memory consistency, or whatever computer science principles the trace demonstrates. Discuss why certain interleavings are problematic and how they relate to theoretical models.
For data structures shown in tabular form: Discuss the theoretical properties, trade-offs, time and space complexity, and applications of the data structures being presented.
For mathematical proofs or formal methods in tables: Explain the logical foundations, proof techniques, and significance of each step in the formal reasoning.
Connect tabular data to broader theoretical frameworks and explain why specific patterns, anomalies, or edge cases in the data are significant for understanding the underlying concepts.
For performance comparisons in tables: Discuss the theoretical reasons behind performance differences, scalability implications, and the fundamental computer science principles that explain the results. CONTENT APPROACH:
Explain concepts as if writing for a graduate-level technical textbook
Focus on the WHY and HOW behind the technical content
Provide context for formulas, algorithms, and data structures
Explain the significance of diagrams, charts, and code examples
Connect concepts to broader principles and applications
Use analogies only when they clarify complex technical relationships
When analyzing execution traces or concurrent systems, explain the theoretical models (sequential consistency, linearizability, etc.) that govern the behavior
For algorithmic content, discuss correctness, complexity, and optimality
For systems content, explain trade-offs, design decisions, and performance implications AVOID:
Conversational phrases or direct image references
Introductory or concluding statements like 'This page shows...' or 'In conclusion...'
Bullet points or structured lists
Speculation about content not clearly visible
Merely restating what is shown without explaining the underlying concepts Write as continuous, flowing paragraphs that explain the technical concepts present on this page, formatted for natural speech synthesis."""
user = "Analyze this image and explain the underlying technical concepts and principles it contains."
  ```
