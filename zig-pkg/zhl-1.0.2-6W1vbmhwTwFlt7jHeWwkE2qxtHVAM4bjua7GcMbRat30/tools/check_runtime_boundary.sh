#!/usr/bin/env sh
set -eu

fail=0
modules='convert_common.zig textmate/root.zig textmate/summary.zig textmate/captures.zig textmate/include.zig textmate/injection.zig textmate/keyword.zig textmate/pattern.zig textmate/import.zig textmate/convert.zig textmate/convert_emit.zig textmate/convert_regex.zig textmate/convert_blocks.zig textmate/plist.zig textmate/reachability.zig textmate/types.zig sublime/root.zig sublime/import.zig sublime/convert.zig sublime/marker.zig'
hit_file=${TMPDIR:-/tmp}/zhl-runtime-boundary-hit.$$
prod_file=${TMPDIR:-/tmp}/zhl-runtime-boundary-prod.$$
trap 'rm -f "$hit_file" "$prod_file"' EXIT HUP INT TERM

if find src -type f -name 'regex_special_*.zig' -print >"$hit_file" 2>/dev/null && [ -s "$hit_file" ]; then
    printf 'language-specific regex specializations are not allowed in runtime code\n' >&2
    cat "$hit_file" >&2
    fail=1
fi

if find src -path src/grammars -prune -o -type f \( \
    -name 'bash.zig' -o \
    -name 'c.zig' -o \
    -name 'javascript.zig' -o \
    -name 'json.zig' -o \
    -name 'python.zig' -o \
    -name 'rust.zig' -o \
    -name 'toml.zig' -o \
    -name 'typescript.zig' -o \
    -name 'yaml.zig' -o \
    -name 'zig_0_16.zig' \
    \) -print >"$hit_file" 2>/dev/null && [ -s "$hit_file" ]; then
    printf 'language-specific source files must live under src/grammars\n' >&2
    cat "$hit_file" >&2
    fail=1
fi

check_file() {
    file=$1
    [ -f "$file" ] || return 0

    for module in $modules; do
        if grep -n "@import(\"$module\")" "$file" >"$hit_file" 2>/dev/null; then
            printf '%s imports offline-only module %s\n' "$file" "$module" >&2
            cat "$hit_file" >&2
            fail=1
        fi
    done

    if grep -nE '@import\("(\.\./)?sublime/' "$file" >"$hit_file" 2>/dev/null; then
        printf '%s imports offline-only Sublime package\n' "$file" >&2
        cat "$hit_file" >&2
        fail=1
    fi

    if grep -n '@import("root.zig")' "$file" >"$hit_file" 2>/dev/null; then
        printf '%s imports root.zig; runtime files must import narrow modules\n' "$file" >&2
        cat "$hit_file" >&2
        fail=1
    fi

    if grep -n 'zhl\.\(convert_common\|textmate_captures\|textmate_include\|textmate_injection\|textmate_keyword\|textmate_pattern\|textmate_import\|textmate_convert\|textmate_plist\|textmate_reachability\|textmate_types\|sublime\|sublime_convert\|sublime_marker\)' "$file" >"$hit_file" 2>/dev/null; then
        printf '%s references offline-only TextMate/Sublime API\n' "$file" >&2
        cat "$hit_file" >&2
        fail=1
    fi
}

check_language_specific_scope() {
    file=$1
    [ -f "$file" ] || return 0
    awk '/^test "/ { exit } { print }' "$file" >"$prod_file"
    if grep -nE '"(source|text|keyword|support|comment|string|constant|entity|meta|variable|storage|punctuation)\.[^"]*\.(zig|rust|python|js|javascript|ts|typescript|c|bash|yaml|toml|json)\b' "$prod_file" >"$hit_file" 2>/dev/null; then
        printf '%s contains language-specific scope logic in production runtime code\n' "$file" >&2
        cat "$hit_file" >&2
        fail=1
    fi
}

for file in \
    src/runtime/engine.zig \
    src/native/format.zig \
    src/runtime/native_runtime.zig \
    src/runtime/dynamic_end.zig \
    src/runtime/sinks.zig \
    src/render/renderers.zig \
    src/runtime/document.zig \
    src/runtime/wasm.zig \
    src/runtime/wasm_export.zig \
    src/tree_sitter/root.zig \
    src/textmate/dynamic/root.zig \
    src/textmate/dynamic/runtime.zig \
    src/textmate/dynamic/anchor.zig \
    src/textmate/dynamic/class.zig \
    src/textmate/dynamic/layout.zig \
    src/textmate/dynamic/line_start.zig \
    src/textmate/dynamic/literal.zig \
    src/textmate/dynamic/prefix.zig \
    src/textmate/dynamic/storage.zig \
    src/grammars/*.zig
do
    check_file "$file"
done

for file in src/regex/*.zig src/textmate/dynamic/*.zig; do
    check_file "$file"
done

for file in \
    src/runtime/engine.zig \
    src/native/format.zig \
    src/runtime/native_runtime.zig \
    src/runtime/dynamic_end.zig \
    src/runtime/sinks.zig \
    src/render/renderers.zig \
    src/runtime/document.zig \
    src/runtime/wasm.zig \
    src/tree_sitter/root.zig
do
    check_language_specific_scope "$file"
done

for file in src/regex/*.zig src/textmate/dynamic/*.zig; do
    check_language_specific_scope "$file"
done

exit "$fail"
