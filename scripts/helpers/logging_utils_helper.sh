#!/usr/bin/env bash
# logging_utils.sh
# Usage: source logging_utils_helper.sh
# Requires: LOG_FILE (variable) be set in the caller

print_line()
{
	echo "======================================================================="
}

log_info()
{
	local timestamp
	timestamp=$(date '+%Y-%m-%d %H:%M:%S')
	local message="[$timestamp] INFO: $*"
	echo "$message"
	if [[ -n ${LOG_FILE:-} ]]; then
		echo "$message" >>"$LOG_FILE"
	fi
}

log_warn()
{
	local timestamp
	timestamp=$(date '+%Y-%m-%d %H:%M:%S')
	local message="[$timestamp] WARN: $*"
	echo "$message"
	if [[ -n ${LOG_FILE:-} ]]; then
		echo "$message" >>"$LOG_FILE"
	fi
	print_line
}

log_success()
{
	local timestamp
	timestamp=$(date '+%Y-%m-%d %H:%M:%S')
	local message="[$timestamp] SUCCESS: $*"
	echo "$message"
	if [[ -n ${LOG_FILE:-} ]]; then
		echo "$message" >>"$LOG_FILE"
	fi
	print_line
}

log_error()
{
	local timestamp
	timestamp=$(date '+%Y-%m-%d %H:%M:%S')
	local message="[$timestamp] ERROR: $*"
	echo "$message" >&2
	if [[ -n ${LOG_FILE:-} ]]; then
		echo "$message" >>"$LOG_FILE"
	fi
	print_line
	return 1
}
