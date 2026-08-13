#!/bin/sh
set -eu

zig=$1
root=$2
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

archive=$temporary/ploof.tar
excludes=$temporary/excludes
printf '%s\n' \
    .git '.git/*' \
    .zig-cache '*/.zig-cache' \
    zig-cache '*/zig-cache' \
    zig-out '*/zig-out' \
    zig-pkg '*/zig-pkg' \
    __pycache__ '*/__pycache__' \
    .pytest_cache '*/.pytest_cache' \
    '*.pyc' '*.pyo' > "$excludes"
tar -C "$root" --exclude-from="$excludes" -cf "$archive" .

for generated in .zig-cache zig-cache zig-out zig-pkg __pycache__ .pytest_cache
do
    sentinel=$temporary/sentinel/tests/nested/$generated
    mkdir -p "$sentinel"
    printf 'must not be packaged\n' > "$sentinel/package-sentinel"
done
printf 'must not be packaged\n' > "$temporary/sentinel/tests/nested/cache.pyc"
tar -C "$temporary/sentinel" --exclude-from="$excludes" -rf "$archive" tests
if tar -tf "$archive" | grep -Eq \
        '(^|/)(\.zig-cache|zig-cache|zig-out|zig-pkg|__pycache__|\.pytest_cache)(/|$)'; then
    echo "package check: generated cache or output entered source tar" >&2
    exit 1
fi
cp "$root/build.zig" "$root/build_fuzz.zig" "$root/build.zig.zon" "$temporary/"
cp -R "$root/build" "$temporary/"

contents=$(
    cd "$temporary"
    "$zig" fetch \
        --global-cache-dir "$temporary/cache" \
        --debug-hash \
        "$archive"
)

if printf '%s\n' "$contents" | grep -Eq \
        '(^|/)(\.zig-cache|zig-cache|zig-out|zig-pkg|__pycache__|\.pytest_cache)(/|$)'; then
    echo "package check: generated cache or output entered package" >&2
    exit 1
fi

if ! printf '%s\n' "$contents" | grep -q ': src/ploof.zig$'; then
    echo "package check: production root missing" >&2
    exit 1
fi

if ! printf '%s\n' "$contents" | grep -q ': tools/ploof-assets.zig$'; then
    echo "package check: asset compiler missing" >&2
    exit 1
fi
