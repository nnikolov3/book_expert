#!/usr/bin/env bash
# get_config_helper.sh
# Usage: get_config_helper.sh <key> [default]

# Fail on error, print help for insufficient args
set -euo pipefail

if [[ $# -lt 1 ]]; then
	echo "Usage: $0 <key> [default]"
	exit 2
fi

declare -r CONFIG_FILE="$PWD/../project.toml"
KEY="$1"
DEFAULT="${2:-}"

if [[ ! -f $CONFIG_FILE ]]; then
	echo "ERROR: Config file not found: $CONFIG_FILE"
	exit 1
fi

VALUE="$(yq -r ".${KEY} // \"\"" "$CONFIG_FILE" 2>&1)"
yq_exit="$?"

if [[ "$yq_exit" -ne 0 ]]; then
	echo "ERROR: yq failed to parse config file for key '$KEY': $VALUE" >&2
	exit 1
fi

if [[ -n $VALUE ]]; then
	echo "$VALUE"
	exit 0
fi

if [[ -n $DEFAULT ]]; then
	echo "$DEFAULT"
	exit 0
fi

echo "ERROR: Missing configuration for key '$KEY' in $CONFIG_FILE"
exit 1
