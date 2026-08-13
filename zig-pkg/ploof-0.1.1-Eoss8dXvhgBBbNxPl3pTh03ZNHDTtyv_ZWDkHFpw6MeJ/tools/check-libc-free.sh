#!/bin/sh
set -eu

binary=$1

if ! readelf -hW "$binary" | grep -q 'Machine:.*X86-64'; then
    echo "libc-free check: expected an x86-64 ELF" >&2
    exit 1
fi

if readelf -lW "$binary" | grep -q ' INTERP '; then
    echo "libc-free check: unexpected dynamic interpreter" >&2
    exit 1
fi

if readelf -dW "$binary" 2>/dev/null | grep -q '(NEEDED)'; then
    echo "libc-free check: unexpected dynamic dependency" >&2
    exit 1
fi

if ! readelf -WsW "$binary" | awk '
    $7 == "UND" && $8 != "" && !($5 == "LOCAL" && $6 == "HIDDEN" && $8 == "_DYNAMIC") {
        print
        bad = 1
    }
    END { exit bad }
'; then
    echo "libc-free check: unexpected unresolved symbol" >&2
    exit 1
fi
