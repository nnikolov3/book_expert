#!/usr/bin/env bash

# Design: Niko Nikolov
# Code: Niko and LLMs

set -euo pipefail

# Logging helpers (extend to also write to file if desired)
log()
{
	echo "INFO: -> $1"
	print_line
}
error()
{
	echo "ERROR: -> $1"
	print_line
}
success()
{
	echo "SUCCESS: -> $1"
	print_line
}
warn()
{
	echo "WARN: -> $1"
	print_line
}
print_line()
{
	echo "================================================================"
}

# Handle script exits and clean up processing directories on exit or signal.
cleanup_on_exit()
{
	local exit_code
	exit_code=$?
	log "Script interrupted or exiting with code $exit_code"

	# Remove old processing directories
	if [[ -n ${PROCESSING_DIR:-} ]]; then
		log "Cleaning up processing directories..."
		find "$PROCESSING_DIR" -name "*_*" -type d -mtime +1 -exec rm -rf {} + 2>/dev/null || true
	fi
	exit $exit_code
}

trap cleanup_on_exit EXIT
trap 'log "Received SIGINT (Ctrl+C), cleaning up..."; exit 130' INT
trap 'log "Received SIGTERM, cleaning up..."; exit 143' TERM

# --- Configuration: These should be defined in project.toml for flexibility ---
declare CONFIG_FILE="$PWD/project.toml"
declare -a GEMINI_MODELS=("gemini-2.5-flash" "gemini-2.5-flash-lite" "gemini-2.5-pro")
declare OUTPUT_DIR=""
declare MAX_RETRIES=5
declare CONCEPT_MODEL=""
declare LOG_DIR=""
declare LOG_FILE=""
declare GOOGLE_API_KEY_VAR=""
declare PROCESSING_DIR=""
declare INPUT_DIR=""
declare API_RETRY_DELAY=60
declare FORCE=0
declare TESSERACT_TEXT=""
declare EXTRACTED_TEXT=""
declare EXTRACTED_CONCEPTS=""
declare GEMINI_RESPONSE=""

# Load values from config file using yq (fail the script if missing)
get_config()
{
	local key="$1"
	local value
	value=$(yq -r ".${key} // \"\"" "$CONFIG_FILE")
	if [[ -z $value ]]; then
		error "Missing or empty configuration key $key in $CONFIG_FILE"
		return 1
	fi
	echo "$value"
	return 0
}

# System dependencies check for reliable automation
check_dependencies()
{
	local deps=("yq" "jq" "curl" "base64" "tesseract" "rsync" "mktemp" "nproc" "awk")
	for dep in "${deps[@]}"; do
		if ! command -v "$dep" >/dev/null; then
			error "'$dep' is not installed."
			exit 1
		fi
	done
	if [[ -n ${GOOGLE_API_KEY_VAR:-} && -z ${!GOOGLE_API_KEY_VAR:-} ]]; then
		error "API key environment variable '$GOOGLE_API_KEY_VAR' is not set or is empty."
		exit 1
	fi
	if [[ -z ${CONCEPT_MODEL:-} ]]; then
		error "CONCEPT_MODEL is not set."
		exit 1
	fi
	log "NO DEPENDENCY ISSUES"
}

# Extract text using Tesseract OCR with enhanced settings for technical content
extract_tesseract_text()
{
	local png_file="$1"
	TESSERACT_TEXT=""

	log "Running Tesseract OCR extraction..."

	# Use eng+equ for English + equations, OEM 3, automatic PSM
	local tesseract_output
	tesseract_output=$(tesseract "$png_file" stdout -l eng+equ --oem 3 2>&1)
	local tesseract_exit_code
	tesseract_exit_code=$?

	if [[ $tesseract_exit_code -eq 0 && -n $tesseract_output ]]; then
		TESSERACT_TEXT="$tesseract_output"
		success "Tesseract extraction completed"
		return 0
	else
		warn "Tesseract produced no output or failed"
		return 1
	fi
}

call_google_api()
{
	local model_name="$1"
	local prompt="$2"
	local b64_content="$3"
	GEMINI_RESPONSE=""

	# Write prompt and image b64 to temp files
	local prompt_file b64_file json_payload_file
	prompt_file=$(mktemp)
	b64_file=$(mktemp)
	json_payload_file=$(mktemp)
	printf "%s" "$prompt" >"$prompt_file"
	printf "%s" "$b64_content" >"$b64_file"

	# Compose API payload as per Gemini docs
	jq -n \
		--rawfile prompt "$prompt_file" \
		--rawfile b64 "$b64_file" '
      {
        contents: [
          {
            parts: [
              { text: $prompt },
              { inlineData: { mimeType: "image/png", data: $b64 } }
            ]
          }
        ]
      }' >"$json_payload_file"

	# Call Gemini API with proper content-type and authentication
	GEMINI_RESPONSE=$(
		curl -sS \
			-H "x-goog-api-key: ${GEMINI_API_KEY}" \
			-H "Content-Type: application/json" \
			-X POST \
			"https://generativelanguage.googleapis.com/v1beta/models/${model_name}:generateContent" \
			-d @"$json_payload_file"
	)

	# Cleanup
	rm -f "$prompt_file" "$b64_file" "$json_payload_file"
	return 0
}

# Try all configured models sequentially, ensuring robust fallback strategy.
try_gemini_models()
{
	local prompt="$1"
	local b64_content="$2"
	local -a models=("${GEMINI_MODELS[@]}")
	GEMINI_RESPONSE=""
	for model in "${models[@]}"; do
		log "Trying model $model..."
		call_google_api "$model" "$prompt" "$b64_content"
		if [[ $GEMINI_RESPONSE ]]; then
			success "Model $model responded successfully"
			return 0
		else
			warn "Trying a different model"
		fi
	done
	error "All Gemini models failed"
	return 1
}

# Extract enhanced text from image, designed to work well with clean_text.sh transformations
extract_text()
{
	log "Enhanced text extraction"
	local b64_content="$1"
	if [[ -z $b64_content ]]; then
		error "Empty base64 content provided to extract_text"
		return 1
	fi

	local prompt="You are a PhD-level STEM technical writer. Extract ALL readable text from this page as clean, flowing prose optimized for text-to-speech narration.
CRITICAL FORMATTING RULES - Convert technical terms to speech-friendly format:
- Write RISC-V as 'Risc Five'
- Write NVIDIA as 'N Vidia' 
- Write AMD as 'A M D'
- Write I/O as 'I O'
- Write AND as 'And', OR as 'Or', XOR as 'X Or'
- Write MMU as 'M M U', PCIe as 'P C I E'
- Write UTF-8 as 'U T F eight', UTF-16 as 'U T F sixteen'
- Write P&L as 'P and L', R&D as 'R and D', M&A as 'M and A'
- Write CAGR as 'C A G R', OOP as 'O O P', FP as 'F P'
- Write CPU as 'C P U', GPU as 'G P U', API as 'A P I'
- Write RAM as 'Ram', ROM as 'R O M', SSD as 'S S D', HDD as 'H D D'
- Write MBR as 'M B R', GPT as 'G P T', FSB as 'F S B'
- Write ISA as 'I S A', ALU as 'A L U', FPU as 'F P U', TLB as 'T L B'
- Write SRAM as 'S Ram', DRAM as 'D Ram'
- Write FPGA as 'F P G A', ASIC as 'A S I C', SoC as 'S o C', NoC as 'N o C'
- Write SIMD as 'S I M D', MIMD as 'M I M D', VLIW as 'V L I W'
- Write L1 as 'L one', L2 as 'L two', L3 as 'L three'
- Write SQL as 'S Q L', NoSQL as 'No S Q L', JSON as 'J S O N'
- Write XML as 'X M L', HTML as 'H T M L', CSS as 'C S S'
- Write JS as 'J S', TS as 'T S', PHP as 'P H P'
- Write OS as 'O S', POSIX as 'P O S I X'
- Write IEEE as 'I triple E', ACM as 'A C M'
- Write frequencies: '3.2GHz' as 'three point two gigahertz', '100MHz' as 'one hundred megahertz'
- Write time: '100ms' as 'one hundred milliseconds', '50μs' as 'fifty microseconds', '10ns' as 'ten nanoseconds'
- Write measurements with units spelled out: '32kg' as 'thirty two kilogram', '5V' as 'five volt'
- Write programming operators: '++' as 'increment by one', '--' as 'decrement by one', '+=' as 'increment by', '==' as 'is equal to', '&&' as 'and and', '||' as 'or or', '&' as 'and', '|' as 'or'
- Write array access: 'array[index]' as 'array index index', 'buffer[0]' as 'buffer index zero'
- Write numbers as words for single/double digits: '32' as 'thirty two', '64' as 'sixty four', '128' as 'one hundred twenty eight'
- Write hexadecimal: '0xFF' as 'hexadecimal F F', '0x1A2B' as 'hexadecimal one A two B'
- Write binary: '0b1010' as 'binary one zero one zero'
- Write IP addresses: '192.168.1.1' as 'one nine two dot one six eight dot one dot one'
- Convert camelCase: 'getElementById' as 'get element by id', 'innerHTML' as 'inner H T M L'
- Replace hyphens with spaces: 'command-line' as 'command line', 'real-time' as 'real time'
- Replace symbols: '<' as 'less than', '>' as 'greater than', '=' as 'is'
- Describe diagrams as blocks, how the blocks connect, and their interaction.
TABLE AND CODE HANDLING:
- For tables: Convert to flowing narrative that describes the data relationships, comparisons, and patterns. Start with 'The table shows...' or 'The data presents...' and describe row by row or column by column as appropriate. Preserve all numerical values and their relationships. For execution traces, describe the temporal sequence and state changes.
- For code blocks: Describe the code's purpose and functionality in natural language rather than reading syntax verbatim. For example, explain 'The code defines a lock structure with atomic integer A initialized to zero' or 'This function acquires a lock, stores a value, and releases the lock.'
- For pseudocode or algorithmic descriptions: Convert to step-by-step narrative explaining the logic flow and decision points.
- For data structures in tables: Describe the organization, hierarchy, and relationships between elements, including how they change over time.
- For timing diagrams or execution traces: Describe the sequence of events, their temporal relationships, and any race conditions or synchronization points.
- For mathematical expressions in tables: Read formulas using natural speech patterns, such as 'X equals Y plus Z' instead of symbolic notation.
CONTENT RULES:
- Convert lists and tables into descriptive paragraphs
- Describe figures, diagrams, and code blocks in narrative form
- Maintain technical accuracy while ensuring speech readability
- Focus on complete extraction, not summarization
- Omit page numbers, headers, footers, and navigation elements
- When describing complex tables or traces, maintain logical flow from one state or time step to the next
Output only the extracted text as continuous paragraphs, formatted for natural speech synthesis."

	for ((attempts = 0; attempts < MAX_RETRIES; attempts++)); do
		EXTRACTED_TEXT=""
		GEMINI_RESPONSE=""
		try_gemini_models "$prompt" "$b64_content"
		if [[ $GEMINI_RESPONSE ]]; then
			EXTRACTED_TEXT=$(timeout 10s jq -r '.candidates[0].content.parts[0].text // empty' <<<"$GEMINI_RESPONSE")
			if [[ $EXTRACTED_TEXT ]]; then
				success "Enhanced text extracted successfully"
				return 0
			else
				warn "Empty or null response from API (attempt $((attempts + 1))/$MAX_RETRIES)"
			fi
		else
			warn "API call failed or invalid response format (attempt $((attempts + 1))/$MAX_RETRIES)"
		fi
		if [[ $((attempts + 1)) -lt $MAX_RETRIES ]]; then
			log "Waiting ${API_RETRY_DELAY}s before retry..."
			sleep "$API_RETRY_DELAY"
		fi
	done
	error "Enhanced text extraction failed after $MAX_RETRIES attempts"
	return 1
}

# Extract concepts optimized for clean_text.sh transformations
extract_concepts()
{
	local b64_content="$1"
	GEMINI_RESPONSE=""
	if [[ -z $b64_content ]]; then
		error "Empty base64 content provided to extract_concepts"
		return 1
	fi

	local prompt="You are a Nobel laureate scientist with expertise across all STEM fields. Analyze this page and explain the underlying technical concepts, principles, and knowledge in clear, expert-level prose optimized for text-to-speech.
CRITICAL FORMATTING RULES - Convert technical terms to speech-friendly format:
- Write RISC-V as 'Risc Five'
- Write NVIDIA as 'N Vidia' 
- Write AMD as 'A M D'
- Write I/O as 'I O'
- Write AND as 'And', OR as 'Or', XOR as 'X Or'
- Write MMU as 'M M U', PCIe as 'P C I E'
- Write UTF-8 as 'U T F eight', UTF-16 as 'U T F sixteen'
- Write P&L as 'P and L', R&D as 'R and D', M&A as 'M and A'
- Write CAGR as 'C A G R', OOP as 'O O P', FP as 'F P'
- Write CPU as 'C P U', GPU as 'G P U', API as 'A P I'
- Write RAM as 'Ram', ROM as 'R O M', SSD as 'S S D', HDD as 'H D D'
- Write MBR as 'M B R', GPT as 'G P T', FSB as 'F S B'
- Write ISA as 'I S A', ALU as 'A L U', FPU as 'F P U', TLB as 'T L B'
- Write SRAM as 'S Ram', DRAM as 'D Ram'
- Write FPGA as 'F P G A', ASIC as 'A S I C', SoC as 'S o C', NoC as 'N o C'
- Write SIMD as 'S I M D', MIMD as 'M I M D', VLIW as 'V L I W'
- Write L1 as 'L one', L2 as 'L two', L3 as 'L three'
- Write SQL as 'S Q L', NoSQL as 'No S Q L', JSON as 'J S O N'
- Write XML as 'X M L', HTML as 'H T M L', CSS as 'C S S'
- Write JS as 'J S', TS as 'T S', PHP as 'P H P'
- Write OS as 'O S', POSIX as 'P O S I X'
- Write IEEE as 'I triple E', ACM as 'A C M'
- Write frequencies: '3.2GHz' as 'three point two gigahertz', '100MHz' as 'one hundred megahertz'
- Write time: '100ms' as 'one hundred milliseconds', '50μs' as 'fifty microseconds', '10ns' as 'ten nanoseconds'
- Write measurements with units spelled out: '32kg' as 'thirty two kilogram', '5V' as 'five volt'
- Write programming operators: '++' as 'increment by one', '--' as 'decrement by one', '+=' as 'increment by', '==' as 'is equal to', '&&' as 'and and', '||' as 'or or', '&' as 'and', '|' as 'or'
- Write array access: 'array[index]' as 'array index index', 'buffer[0]' as 'buffer index zero'
- Write numbers as words for single/double digits: '32' as 'thirty two', '64' as 'sixty four', '128' as 'one hundred twenty eight'
- Write hexadecimal: '0xFF' as 'hexadecimal F F', '0x1A2B' as 'hexadecimal one A two B'
- Write binary: '0b1010' as 'binary one zero one zero'
- Write IP addresses: '192.168.1.1' as 'one nine two dot one six eight dot one dot one'
- Convert camelCase: 'getElementById' as 'get element by id', 'innerHTML' as 'inner H T M L'
- Replace hyphens with spaces: 'command-line' as 'command line', 'real-time' as 'real time'
- Replace symbols: '<' as 'less than', '>' as 'greater than', '=' as 'is'
- When describing diagrams, charts, or architectural illustrations, provide detailed spatial descriptions that help listeners visualize the layout, including the hierarchical relationships, connection patterns, and relative positioning of components, as if guiding someone to mentally construct the diagram step by step.
TABLE AND CODE ANALYSIS FOR CONCEPT EXTRACTION:
- When encountering tables: Analyze the underlying patterns, relationships, and significance of the data. Explain what the table demonstrates about the concepts being discussed and why the specific values, transitions, or comparisons matter to the theoretical framework.
- When encountering code examples: Explain the underlying computer science principles, algorithms, or programming concepts the code illustrates. Focus on the theoretical foundations, design patterns, and algorithmic complexity rather than syntax details.
- For execution traces or timing diagrams: Explain the fundamental concepts of concurrency, synchronization, race conditions, memory consistency, or whatever computer science principles the trace demonstrates. Discuss why certain interleavings are problematic and how they relate to theoretical models.
- For data structures shown in tabular form: Discuss the theoretical properties, trade-offs, time and space complexity, and applications of the data structures being presented.
- For mathematical proofs or formal methods in tables: Explain the logical foundations, proof techniques, and significance of each step in the formal reasoning.
- Connect tabular data to broader theoretical frameworks and explain why specific patterns, anomalies, or edge cases in the data are significant for understanding the underlying concepts.
- For performance comparisons in tables: Discuss the theoretical reasons behind performance differences, scalability implications, and the fundamental computer science principles that explain the results.
CONTENT APPROACH:
- Explain concepts as if writing for a graduate-level technical textbook
- Focus on the WHY and HOW behind the technical content
- Provide context for formulas, algorithms, and data structures
- Explain the significance of diagrams, charts, and code examples
- Connect concepts to broader principles and applications
- Use analogies only when they clarify complex technical relationships
- When analyzing execution traces or concurrent systems, explain the theoretical models (sequential consistency, linearizability, etc.) that govern the behavior
- For algorithmic content, discuss correctness, complexity, and optimality
- For systems content, explain trade-offs, design decisions, and performance implications
AVOID:
- Conversational phrases or direct image references
- Introductory or concluding statements like 'This page shows...' or 'In conclusion...'
- Bullet points or structured lists
- Speculation about content not clearly visible
- Merely restating what is shown without explaining the underlying concepts
Write as continuous, flowing paragraphs that explain the technical concepts present on this page, formatted for natural speech synthesis."

	for ((attempts = 0; attempts < MAX_RETRIES; attempts++)); do
		GEMINI_RESPONSE=""
		EXTRACTED_CONCEPTS=""
		try_gemini_models "$prompt" "$b64_content"
		if [[ $GEMINI_RESPONSE ]]; then
			EXTRACTED_CONCEPTS=$(timeout 10s jq -r '.candidates[0].content.parts[0].text // empty' <<<"$GEMINI_RESPONSE")
			if [[ $EXTRACTED_CONCEPTS ]]; then
				success "Concepts extracted successfully"
				return 0
			else
				warn "Empty or null response from API (attempt $((attempts + 1))/$MAX_RETRIES)"
				log "Waiting ${API_RETRY_DELAY}s before retry..."
				sleep "$API_RETRY_DELAY"
				continue
			fi
		fi
	done

	error "Concept extraction failed after $MAX_RETRIES attempts"
	return 1
}

# Process one PNG file with three-stage extraction: Tesseract -> API Text -> API Concepts
process_single_png()
{
	local png="$1"
	local storage_dir="$2"
	local max_retries="${MAX_RETRIES:-5}"
	local retries=0
	local base_name
	local output_file
	local b64_content
	local base64_exit_code=0

	TESSERACT_TEXT=""
	EXTRACTED_TEXT=""
	EXTRACTED_CONCEPTS=""
	base_name=$(basename "$png" .png)
	output_file="$storage_dir/${base_name}.txt"
	mkdir -p "$storage_dir"

	# Skip processing if text output already exists (idempotent workflow)
	if [[ -s $output_file ]]; then
		log "SKIP: $png already processed."
		return 0
	fi

	# Prepare base64 content for API calls
	b64_content=$(base64 -w 0 "$png" 2>&1)
	base64_exit_code=$?
	if [[ $base64_exit_code -ne 0 ]]; then
		error "Base64 encoding failed for file: $png - $b64_content"
		return 1
	fi
	if [[ -z $b64_content ]]; then
		error "Base64 encoding produced empty result for file: $png"
		return 1
	fi

	while [[ $retries -lt $max_retries ]]; do
		log "Processing: $png"

		# Stage 1: Tesseract OCR extraction
		TESSERACT_TEXT=""
		if extract_tesseract_text "$png"; then
			echo "$TESSERACT_TEXT" >>"$output_file"
			success "Tesseract text appended to '$output_file'"
		else
			warn "Tesseract extraction failed, continuing with API extraction only"
			echo "=== TESSERACT OCR EXTRACTION ===" >"$output_file"
			echo "[Tesseract extraction failed]" >>"$output_file"
			echo "" >>"$output_file"
		fi

		# Stage 2: Enhanced API text extraction
		EXTRACTED_TEXT=""
		if extract_text "${b64_content}"; then
			echo "$EXTRACTED_TEXT" >>"$output_file"

			success "Enhanced text appended to '$output_file'"

			# Stage 3: Concept extraction
			EXTRACTED_CONCEPTS=""
			if extract_concepts "$b64_content"; then

				echo "$EXTRACTED_CONCEPTS" >>"$output_file"
				success "Concepts appended to '$output_file'"
				success "All three stages completed for $output_file"
				TESSERACT_TEXT=""
				EXTRACTED_TEXT=""
				EXTRACTED_CONCEPTS=""
				return 0
			else
				warn "Concept extraction failed for: $png"
			fi
		else
			warn "Enhanced text extraction failed for: $png"
		fi

		retries=$((retries + 1))
		if [[ $retries -lt $max_retries ]]; then
			log "RETRYING $png (attempt $((retries + 1))/$max_retries)"
			sleep "$API_RETRY_DELAY"
		else
			error "FAILED TO PROCESS $png"
		fi
	done
	error "Failed to process $png after $max_retries retries"
	return 1
}

# Batch process all PNGs in a directory.
process_pngs()
{
	local -a png_files=("$@")
	local storage_dir="${png_files[-1]}"
	unset 'png_files[-1]'
	for png in "${png_files[@]}"; do
		if ! process_single_png "$png" "$storage_dir"; then
			error "Failed to process $png"
		fi
	done
	log "All processing complete."
}

# Setup processing dirs, verify staged files, trigger actual PNG processing.
pre_process_png()
{
	local png_directory="$1"
	local processing_png_dir="$2"
	local storage_dir="$3"

	mkdir -p "$PROCESSING_DIR"
	mkdir -p "$storage_dir"
	log "STORAGE: $storage_dir"

	# Name per document, separate temp dir for each run.
	local safe_name
	safe_name=$(echo "$processing_png_dir" | tr '/' '_')
	log "Removing old TEMP directories with the same base directory"
	rm -rf "$PROCESSING_DIR/${safe_name}"_*
	local temp_dir
	temp_dir=$(mktemp -d "$PROCESSING_DIR/${safe_name}_XXXXXX")
	log "STAGING TO NEW PROCESSING DIR: $temp_dir"

	rsync -a --info=progress2 "$png_directory/" "$temp_dir/"
	local output
	output=$(rsync -a --checksum --dry-run "$png_directory/" "$temp_dir/")
	if [[ -z $output ]]; then
		success "STAGING COMPLETE"
	else
		error "Files differ:"
		error "$output"
	fi

	# List all PNGs to process in order
	declare -a png_array=()
	mapfile -t png_array < <(find "$temp_dir" -type f -name "*.png" | sort -V)
	if [ ${#png_array[@]} -eq 0 ]; then
		error "No png files? This is odd."
		return 1
	else
		success "Found pngs. Processing ..."
		if process_pngs "${png_array[@]}" "$storage_dir"; then
			success "PNG processing completed successfully for $temp_dir"
		else
			error "PNG processing failed"
			return 1
		fi
	fi
}

# Find document directories that need processing, create processing queue.
declare -a PNG_DIRS_GLOBAL=()
are_png_in_dirs()
{
	local -a pdf_array=("$@")
	PNG_DIRS_GLOBAL=()
	local dir_path
	local text_path
	local png_count
	local text_count

	for pdf_name in "${pdf_array[@]}"; do
		log "Checking document: $pdf_name"
		dir_path="$OUTPUT_DIR/$pdf_name/png"
		text_path="$OUTPUT_DIR/$pdf_name/text"
		text_count=0
		png_count=0
		if [[ -d $text_path ]]; then
			text_count=$(find "$text_path" -type f | wc -l)
		fi
		if [[ -d $dir_path ]]; then
			png_count=$(find "$dir_path" -type f -name "*.png" | wc -l)
			if [[ $png_count -eq $text_count ]]; then
				log "SKIPPING $dir_path"
				log "Remove the text directory if you want to generate the text"
			elif [[ $png_count -gt 0 && $text_count -gt 0 && $FORCE -eq 0 ]]; then
				log "SKIPPING $dir_path"
				log "Remove the text directory if you want to generate the text"
			elif [[ $png_count -gt 0 && $text_count -gt 0 && $FORCE -eq 1 ]]; then
				log "$dir_path exists and contains $png_count file(s)"
				log "Force is $FORCE"
				log "$text_path has $text_count text files, the process will resume after the last text file"
				PNG_DIRS_GLOBAL+=("$dir_path")
			elif [[ $png_count -gt 0 ]]; then
				log "Adding $dir_path in the processing queue"
				PNG_DIRS_GLOBAL+=("$dir_path")
			else
				log "Normally, it should not reach here"
			fi
		else
			log "$dir_path does not exist"
		fi
	done

	if [[ ${#PNG_DIRS_GLOBAL[@]} -eq 0 ]]; then
		error "No directories with valid PNG files found"
		return 1
	else
		success "Found directories to process"
		return 0
	fi
}

# Utility: get base and parent dir for naming temp dirs.
get_last_two_dirs()
{
	local full_path="$1"
	local parent_dir
	parent_dir=$(basename "$(dirname "$full_path")")
	local current_dir
	current_dir=$(basename "$full_path")
	echo "$parent_dir/$current_dir"
}

# Entrypoint: initialize, config, discover, process, clean up.
main()
{
	local date_time
	date_time=$(date +%c)
	log "START CONVERSION: $date_time"
	log "Loading configurations"
	INPUT_DIR=$(get_config "paths.input_dir")
	OUTPUT_DIR=$(get_config "paths.output_dir")
	CONCEPT_MODEL=$(get_config "nvidia_api.concept_model")
	LOG_DIR=$(get_config "logs_dir.png_to_text")
	PROCESSING_DIR=$(get_config "processing_dir.png_to_text")
	MAX_RETRIES=$(get_config "retry.max_retries")
	API_RETRY_DELAY=$(get_config "retry.retry_delay_seconds")
	GOOGLE_API_KEY_VAR=$(get_config "google_api.api_key_variable")
	FORCE=$(get_config "settings.force")
	mkdir -p "$PROCESSING_DIR"
	mkdir -p "$LOG_DIR" || {
		error "Failed to create log directory: $LOG_DIR"
		exit 1
	}
	LOG_FILE="$LOG_DIR/log_$(date +'%Y%m%d_%H%M%S').log"
	touch "$LOG_FILE" || {
		error "Failed to create log file."
		exit 1
	}
	log "Script started. Log file: $LOG_FILE"
	log "Checking dependencies"
	check_dependencies

	declare -a pdf_array=()
	mapfile -t pdf_array < <(find "$INPUT_DIR" -type f -name "*.pdf" -exec basename {} .pdf \;)
	if [ ${#pdf_array[@]} -eq 0 ]; then
		error "No pdf files in input directory"
		exit 1
	else
		log "Found pdf for processing. Checking for valid png .."
	fi

	if are_png_in_dirs "${pdf_array[@]}"; then
		for png_path in "${PNG_DIRS_GLOBAL[@]}"; do
			log "PROCESSING: $png_path"
			staging_dir_name=$(get_last_two_dirs "$png_path")
			parent_dir=$OUTPUT_DIR/$(basename "$(dirname "$png_path")")/text
			pre_process_png "$png_path" "$staging_dir_name" "$parent_dir"
		done
	fi

	log "All processing jobs completed."
	log "CLEANING UP"
	cleanup_on_exit
}

main "$@"
