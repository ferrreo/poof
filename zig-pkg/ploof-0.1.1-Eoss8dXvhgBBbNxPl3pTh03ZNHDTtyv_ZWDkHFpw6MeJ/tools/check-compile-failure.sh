#!/bin/sh
set -eu

expected=$1
shift
output=$(mktemp)
trap 'rm -f "$output"' EXIT HUP INT TERM

if "$@" >"$output" 2>&1; then
    echo "expected compilation to fail: $expected" >&2
    exit 1
fi

if ! grep -F -- "$expected" "$output" >/dev/null; then
    echo "expected compiler output to contain: $expected" >&2
    cat "$output" >&2
    exit 1
fi
