#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
gate=${1:?usage: run-external-gate.sh GATE_ID}
artifact=${2-}
variable=PLOOF_$(printf '%s' "$gate" | tr '[:lower:].-' '[:upper:]__')_COMMAND
command=$(printenv "$variable" || true)

reject_symlink_path() {
    path=$1
    if [ -L "$path" ]; then
        echo "external gate: refusing symlink artifact path: $path" >&2
        exit 1
    fi
    parent=$(dirname -- "$path")
    while [ "$parent" != . ] && [ "$parent" != / ]; do
        if [ -L "$parent" ]; then
            echo "external gate: refusing symlink artifact parent: $parent" >&2
            exit 1
        fi
        next=$(dirname -- "$parent")
        [ "$next" != "$parent" ] || break
        parent=$next
    done
}

if [ -z "$command" ]; then
    echo "external gate: required runner variable is unset: $variable" >&2
    exit 1
fi
if [ -n "$artifact" ]; then
    reject_symlink_path "$artifact"
fi
if [ -n "$artifact" ] && [ -e "$artifact" ]; then
    echo "external gate: refusing stale artifact: $artifact" >&2
    exit 1
fi
if [ -n "$artifact" ]; then
    mkdir -p "$(dirname "$artifact")"
    reject_symlink_path "$artifact"
fi
PLOOF_GATE_ARTIFACT=$artifact /bin/bash -euo pipefail -c "$command"
if [ -n "$artifact" ] && { [ ! -f "$artifact" ] || [ -L "$artifact" ]; }; then
    echo "external gate: command did not create regular artifact: $artifact" >&2
    exit 1
fi
if [ -n "$artifact" ]; then
    if [ -z "${PLOOF_CANDIDATE_REVISION-}" ]; then
        echo "external gate: candidate revision is unset" >&2
        exit 1
    fi
    if ! tar -tf "$artifact" >/dev/null 2>&1; then
        echo "external gate: evidence artifact is not a readable tar: $artifact" >&2
        exit 1
    fi
    if [ -z "$(tar -tf "$artifact" | sed -n '1p')" ]; then
        echo "external gate: evidence tar is empty: $artifact" >&2
        exit 1
    fi
    python3 "$root/tools/verify-external-evidence.py" \
        --root "$root" \
        --gate "$gate" \
        --revision "$PLOOF_CANDIDATE_REVISION" \
        --artifact "$artifact"
fi
