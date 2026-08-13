#!/bin/sh
set -eu

case "${1-}" in
    version|env)
        exec "$PLOOF_REAL_ZIG" "$@"
        ;;
    build)
        trap '' TERM
        while :; do
            sleep 1
        done
        ;;
    *)
        echo "unexpected fake Zig command: ${1-}" >&2
        exit 2
        ;;
esac
