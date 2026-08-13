#!/bin/sh
set -eu

doc=docs/public_api.md
root=src/root.zig
engine=src/runtime/engine.zig
sinks=src/runtime/sinks.zig
renderers=src/render/renderers.zig
document=src/runtime/document.zig
tree_sitter=src/tree_sitter/root.zig
binary=src/runtime/binary.zig
zhlb_doc=docs/zhlb.md
exports_file=${TMPDIR:-/tmp}/zhl-public-api-exports.$$
doc_exports_file=${TMPDIR:-/tmp}/zhl-public-api-doc-exports.$$
options_file=${TMPDIR:-/tmp}/zhl-engine-options.$$
doc_options_file=${TMPDIR:-/tmp}/zhl-public-api-options.$$
errors_file=${TMPDIR:-/tmp}/zhl-highlight-errors.$$
doc_errors_file=${TMPDIR:-/tmp}/zhl-public-api-errors.$$
generated_file=${TMPDIR:-/tmp}/zhl-generated-grammar-files.$$
trap 'rm -f "$exports_file" "$doc_exports_file" "$options_file" "$doc_options_file" "$errors_file" "$doc_errors_file" "$generated_file"' EXIT HUP INT TERM

[ -f "$doc" ] || { printf 'missing %s\n' "$doc" >&2; exit 1; }

exports=$(awk '/^pub const / {
    name=$3
    sub(/=.*/, "", name)
    sub(/;.*/, "", name)
    print name
}' "$root")
printf '%s\n' "$exports" | sort >"$exports_file"

ok=1
for name in $exports; do
    if ! grep -F -- "- \`$name\`" "$doc" >/dev/null; then
        printf 'public export missing from docs: %s\n' "$name" >&2
        ok=0
    fi
done

awk '
    /^## Runtime API/ { in_exports = 1; next }
    /^`sinks` exports/ { in_exports = 0; next }
    /^`EngineOptions` fields/ { in_exports = 0; next }
    /^## Grammar And Compiler API/ { in_exports = 1; next }
    /^## Regex API/ { in_exports = 1; next }
    /^## Generated Grammar ABI/ { in_exports = 0; next }
    in_exports && /^- `[^`]+`$/ {
        name = $0
        sub(/^- `/, "", name)
        sub(/`$/, "", name)
        print name
    }
' "$doc" | sort >"$doc_exports_file"

while IFS= read -r name; do
    if ! grep -Fx "$name" "$exports_file" >/dev/null; then
        printf 'public docs mention non-exported root symbol: %s\n' "$name" >&2
        ok=0
    fi
done <"$doc_exports_file"

awk '
    /^pub const EngineOptions = struct {/ { in_options = 1; next }
    in_options && /^};/ { in_options = 0; next }
    in_options && /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*:/ {
        name = $1
        sub(/:.*/, "", name)
        print name
    }
' "$engine" | sort >"$options_file"

awk '
    /^`EngineOptions` fields/ { in_options = 1; next }
    /^`HighlightError` members/ { in_options = 0; next }
    /^## Grammar And Compiler API/ { in_options = 0; next }
    in_options && /^- `[^`]+`$/ {
        name = $0
        sub(/^- `/, "", name)
        sub(/`$/, "", name)
        print name
    }
' "$doc" | sort >"$doc_options_file"

while IFS= read -r name; do
    if ! grep -Fx "$name" "$doc_options_file" >/dev/null; then
        printf 'EngineOptions field missing from docs: %s\n' "$name" >&2
        ok=0
    fi
done <"$options_file"

while IFS= read -r name; do
    if ! grep -Fx "$name" "$options_file" >/dev/null; then
        printf 'public docs mention non-existent EngineOptions field: %s\n' "$name" >&2
        ok=0
    fi
done <"$doc_options_file"

awk '
    /^pub const HighlightError = error{/ { in_errors = 1; next }
    in_errors && /^};/ { in_errors = 0; next }
    in_errors && /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*,/ {
        name = $1
        sub(/,/, "", name)
        print name
    }
' "$engine" | sort >"$errors_file"

awk '
    /^`HighlightError` members/ { in_errors = 1; next }
    /^## Grammar And Compiler API/ { in_errors = 0; next }
    in_errors && /^- `[^`]+`$/ {
        name = $0
        sub(/^- `/, "", name)
        sub(/`$/, "", name)
        print name
    }
' "$doc" | sort >"$doc_errors_file"

while IFS= read -r name; do
    if ! grep -Fx "$name" "$doc_errors_file" >/dev/null; then
        printf 'HighlightError member missing from docs: %s\n' "$name" >&2
        ok=0
    fi
done <"$errors_file"

while IFS= read -r name; do
    if ! grep -Fx "$name" "$errors_file" >/dev/null; then
        printf 'public docs mention non-existent HighlightError member: %s\n' "$name" >&2
        ok=0
    fi
done <"$doc_errors_file"

for name in NullSink DebugSink TokenBuffer; do
    if ! grep -Eq "^pub (const|fn) $name\\b" "$sinks"; then
        printf 'sink helper missing from source: %s\n' "$name" >&2
        ok=0
    fi
    if ! grep -F -- "- \`$name\`" "$doc" >/dev/null; then
        printf 'sink helper missing from docs: %s\n' "$name" >&2
        ok=0
    fi
done

for name in renderAnsiLine renderHtmlLine renderDebugLine; do
    if ! grep -Eq "^pub fn $name\\b" "$renderers"; then
        printf 'renderer helper missing from source: %s\n' "$name" >&2
        ok=0
    fi
    if ! grep -F -- "- \`$name\`" "$doc" >/dev/null; then
        printf 'renderer helper missing from docs: %s\n' "$name" >&2
        ok=0
    fi
done

for name in DirtyRange LineCache; do
    if ! grep -Eq "^pub (const|fn) $name\\b" "$document"; then
        printf 'document helper missing from source: %s\n' "$name" >&2
        ok=0
    fi
    if ! grep -F -- "- \`$name\`" "$doc" >/dev/null; then
        printf 'document helper missing from docs: %s\n' "$name" >&2
        ok=0
    fi
done

for name in LanguageId no_language Capture styleFromCaptureName applyOverlay applyAdapterLine applyOverlayLine; do
    if ! grep -Eq "^pub (const|fn) $name\\b" "$tree_sitter"; then
        printf 'tree_sitter helper missing from source: %s\n' "$name" >&2
        ok=0
    fi
    if ! grep -F -- "- \`$name\`" "$doc" >/dev/null; then
        printf 'tree_sitter helper missing from docs: %s\n' "$name" >&2
        ok=0
    fi
done

find src/grammars -maxdepth 1 -type f -name '*.zig' ! -name 'root.zig' | sort >"$generated_file"
while IFS= read -r file; do
    if ! grep -q '^pub const name' "$file"; then
        printf 'checked grammar module missing pub const name: %s\n' "$file" >&2
        ok=0
    fi
    if ! grep -q '^pub const grammar' "$file"; then
        printf 'checked grammar module missing pub const grammar: %s\n' "$file" >&2
        ok=0
    fi
done <"$generated_file"

version=$(sed -n 's/^pub const version:.*= \([0-9][0-9]*\);$/\1/p' "$binary")
[ -n "$version" ] || { printf 'missing zhlb version in %s\n' "$binary" >&2; exit 1; }
for file in "$doc" "$zhlb_doc"; do
    if ! grep -F "zhlb v$version" "$file" >/dev/null; then
        printf 'zhlb version drift in %s: expected zhlb v%s\n' "$file" "$version" >&2
        ok=0
    fi
done

[ "$ok" -eq 1 ]
