#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
    echo "usage: $0 ZIG RUN_FUZZ HANG_FIXTURE" >&2
    exit 2
fi

zig=$1
run_fuzz=$2
hang_fixture=$3
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
output=$temporary/output
cache=$temporary/cache

set +e
bash "$run_fuzz" "$zig" "$cache" fuzz-crash-gate-fixture 1 60 > "$output" 2>&1
status=$?
set -e
if [ "$status" -eq 0 ]; then
    echo "deliberate fuzz crash returned success" >&2
    cat "$output" >&2
    exit 1
fi
if [ ! -f "$cache/f/crash" ]; then
    echo "deliberate fuzz crash did not preserve its input" >&2
    cat "$output" >&2
    exit 1
fi
if ! grep -Fq 'nested fuzz build failed with status' "$output"; then
    echo "patched fuzz runner did not propagate failure status" >&2
    cat "$output" >&2
    exit 1
fi
if ! grep -Fq 'fuzz crash input saved to' "$output"; then
    echo "fuzz wrapper did not report the crash artifact" >&2
    cat "$output" >&2
    exit 1
fi

sharded_output=$temporary/sharded-output
sharded_cache=$temporary/sharded-cache
set +e
bash "$run_fuzz" "$zig" "$sharded_cache" \
    fuzz-crash-gate-fixture 4 60 4 > "$sharded_output" 2>&1
sharded_status=$?
set -e
if [ "$sharded_status" -eq 0 ]; then
    echo "sharded deliberate fuzz crash returned success" >&2
    cat "$sharded_output" >&2
    exit 1
fi
if ! grep -Fq 'one or more fuzz shards failed' "$sharded_output"; then
    echo "sharded fuzz wrapper did not propagate failure" >&2
    cat "$sharded_output" >&2
    exit 1
fi
if ! find "$sharded_cache/fuzz-shards/fuzz-crash-gate-fixture" \
    -path '*/f/crash' -type f -print -quit | grep -q .
then
    echo "sharded deliberate fuzz crash did not preserve an input" >&2
    cat "$sharded_output" >&2
    exit 1
fi

hang_output=$temporary/hang-output
hang_cache=$temporary/hang-cache
set +e
PLOOF_REAL_ZIG=$zig bash "$run_fuzz" \
    "$hang_fixture" "$hang_cache" fuzz-never-completes 1 1 > "$hang_output" 2>&1
hang_status=$?
set -e
if [ "$hang_status" -eq 0 ]; then
    echo "deliberate fuzz hang returned success" >&2
    cat "$hang_output" >&2
    exit 1
fi
if ! grep -Fq 'fuzz campaign exceeded 1-second deadline' "$hang_output"; then
    echo "fuzz wrapper did not report its campaign deadline" >&2
    cat "$hang_output" >&2
    exit 1
fi
