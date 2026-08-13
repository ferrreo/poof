#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: run-fuzz-matrix.sh RUNS" >&2
    exit 2
fi
runs=$1
case "$runs" in
    *[!0-9]*|'') echo "fuzz matrix: RUNS must be a positive integer" >&2; exit 2 ;;
    0) echo "fuzz matrix: RUNS must be positive" >&2; exit 2 ;;
esac
timeout_seconds=3600

families='http1 multipart csrf html upload upload-worker routing url static assets
observability runtime stream-wake stream-lifecycle stream-response stream-driver'

for family in $families; do
    zig build "fuzz-$family" \
        -Dfuzz-runs="$runs" -Dfuzz-timeout-seconds="$timeout_seconds"
    for suffix in -release-safe -release-fast; do
        zig build "fuzz-$family$suffix" \
            -Dfuzz-runs="$runs" -Dfuzz-timeout-seconds="$timeout_seconds"
    done
done
