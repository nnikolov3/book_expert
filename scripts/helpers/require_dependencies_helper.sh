#!/usr/bin/env bash
# require_dependencies_helper.sh
# Usage: require_dependencies_helper.sh <command1> [command2] [command3] ...

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <command1> [command2] [command3] ..." >&2
    exit 2
fi

declare -a missing_deps=()
declare dep=""
declare have=""

for dep in "$@"; do
    have=""
    if command -v "$dep" >/dev/null 2>&1; then
        have="found"
    fi
    if [[ -z "$have" ]]; then
        missing_deps+=("$dep")
    fi
done

if [[ "${#missing_deps[@]}" -gt 0 ]]; then
    echo "ERROR: Required commands not found: ${missing_deps[*]}" >&2
    exit 1
fi

exit 0