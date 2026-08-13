#!/usr/bin/env sh
set -eu

fail=0
corpus_root=${ZHL_CORPUS_CACHE:-.zig-cache/zhl-corpus}
native_names_file=${TMPDIR:-/tmp}/zhl-native-grammar-names.$$
native_exports_file=${TMPDIR:-/tmp}/zhl-native-grammar-exports.$$
trap 'rm -f "$native_names_file" "$native_exports_file"' EXIT HUP INT TERM

ZHL_CORPUS_CACHE=$corpus_root sh tools/fetch_corpus_cache.sh >/dev/null

corpus_path() {
    printf '%s/%s' "$corpus_root" "$1"
}

check_count() {
    label=$1
    expected=$2
    actual=$3
    if [ "$actual" != "$expected" ]; then
        printf '%s count drifted: got %s expected %s\n' "$label" "$actual" "$expected" >&2
        fail=1
    fi
}

unique_sublime_sources() {
    dir=$1
    find "$dir" -maxdepth 1 -type f -name '*.sublime-syntax.part*' |
        while IFS= read -r path; do
            base=${path##*/}
            printf '%s\n' "${base%.sublime-syntax.part??}"
        done |
        sort -u |
        wc -l
}

unique_textmate_sources() {
    dir=$1
    find "$dir" -maxdepth 1 -type f -name '*.tmLanguage.json.part*' |
        while IFS= read -r path; do
            base=${path##*/}
            printf '%s\n' "${base%.tmLanguage.json.part??}"
        done |
        sort -u |
        wc -l
}

native_exports() {
    awk '/^pub const [a-z0-9_]+ = @import\("/ {
        name=$3
        sub(/=.*/, "", name)
        sub(/;.*/, "", name)
        if (name != "zig_0_16_generated") print name
    }' src/grammars/root.zig | sort
}

native_grammar_names() {
    find grammars -maxdepth 1 -type f -name '*.zhl' |
        while IFS= read -r path; do
            base=${path##*/}
            printf '%s\n' "${base%.zhl}"
        done |
        sort
}

native_pack_names() {
    find grammars -maxdepth 1 -type f -name '*.zhlb' |
        while IFS= read -r path; do
            base=${path##*/}
            printf '%s\n' "${base%.zhlb}"
        done |
        sort
}

textmate_source_names() {
    find "$(corpus_path grammars/textmate)" -maxdepth 1 -type f -name '*.tmLanguage.json' |
        while IFS= read -r path; do
            base=${path##*/}
            printf '%s\n' "${base%.tmLanguage.json}"
        done |
        sort
}

textmate_pack_names() {
    find "$(corpus_path grammars/textmate-packs)" -maxdepth 1 -type f -name '*.zhlb' |
        while IFS= read -r path; do
            base=${path##*/}
            printf '%s\n' "${base%.zhlb}"
        done |
        sort
}

sublime_source_names() {
    for first in "$(corpus_path grammars/sublime)"/*.sublime-syntax.part00; do
        [ -e "$first" ] || continue
        base=${first##*/}
        base=${base%.sublime-syntax.part00}
        printf '%s\n' "$base" | tr '[:upper:]' '[:lower:]'
    done |
        sort
}

sublime_pack_names() {
    find "$(corpus_path grammars/sublime-packs)" -maxdepth 1 -type f -name '*.zhlb' |
        while IFS= read -r path; do
            base=${path##*/}
            printf '%s\n' "${base%.zhlb}"
        done |
        sort
}

external_textmate_fixture_names() {
    find "$(corpus_path tests/fixtures/textmate_external)" -maxdepth 1 -type f -name '*.tmLanguage.json.part00' |
        while IFS= read -r path; do
            base=${path##*/}
            printf '%s\n' "${base%.tmLanguage.json.part00}"
        done |
        sort
}

expected_external_textmate_fixture_names() {
    cat <<'EOF'
ASPVBNet
Batch
Bibtex
Clojure
CSS
Dart
Diff
Docker
Dotenv
GitCommit
GitRebase
Go
HLSL
HTML
Ignore
INI
Java
JavaScript
JavaScriptReact
JSON
JSONC
JSONL
MagicRegExp
Makefile
ObjectiveC
PowerShell
Python
R
Rust
SassDoc
SCSS
ShaderLab
Shell
SQL
Swift
TeX
TypeScript
TypeScriptReact
XML
XSL
EOF
}

external_textmate_plist_fixture_names() {
    find "$(corpus_path tests/fixtures/textmate_plist_external)" -maxdepth 1 -type f -name '*.tmLanguage' ! -name 'host.tmLanguage' ! -name 'embedded.tmLanguage' |
        while IFS= read -r path; do
            base=${path##*/}
            printf '%s\n' "${base%.tmLanguage}"
        done |
        sort
}

expected_external_textmate_plist_fixture_names() {
    cat <<'EOF'
Ada
ANTLR
Apache
Diff
DOT
GitCommit
Ini
JavaScriptNextJSON
EOF
}

external_sublime_fixture_names() {
    find "$(corpus_path tests/fixtures/sublime_external)" -maxdepth 1 -type f -name '*.sublime-syntax.part00' |
        while IFS= read -r path; do
            base=${path##*/}
            printf '%s\n' "${base%.sublime-syntax.part00}"
        done |
        sort
}

expected_external_sublime_fixture_names() {
    cat <<'EOF'
C
CSS
Diff
Diff (Basic)
Git Config
Go
HTML
HTML (Plain)
JavaProperties
JavaScript
JSON
Lua
Markdown
Python
Rust
TOML
TypeScript
XML
YAML
EOF
}

sublime_extends_count() {
    dir=$1
    sublime_extends_values "$dir" | wc -l
}

sublime_extends_targets() {
    dir=$1
    sublime_extends_values "$dir" |
        sort -u |
        wc -l
}

sublime_extends_values() {
    dir=$1
    for first in "$dir"/*.sublime-syntax.part00; do
        [ -e "$first" ] || continue
        base=${first##*/}
        base=${base%.sublime-syntax.part00}
        cat "$dir/${base}.sublime-syntax.part"* | sublime_extends_values_for_stream
    done
}

sublime_syntax_include_count() {
    dir=$1
    sublime_syntax_include_values "$dir" | wc -l
}

sublime_syntax_include_targets() {
    dir=$1
    sublime_syntax_include_values "$dir" |
        sort -u |
        wc -l
}

sublime_syntax_include_values() {
    dir=$1
    for first in "$dir"/*.sublime-syntax.part00; do
        [ -e "$first" ] || continue
        base=${first##*/}
        base=${base%.sublime-syntax.part00}
        cat "$dir/${base}.sublime-syntax.part"*
    done |
        grep '^[[:space:]]*-*[[:space:]]*include:[[:space:]].*\.sublime-syntax' 2>/dev/null |
        sed 's/^[[:space:]]*-*[[:space:]]*include:[[:space:]]*//' |
        sed "s/^['\"]//; s/['\"]$//"
}

check_name_set() {
    label=$1
    expected_cmd=$2
    actual_cmd=$3
    eval "$expected_cmd" | sort >"$native_names_file"
    eval "$actual_cmd" | sort >"$native_exports_file"
    if ! diff -u "$native_names_file" "$native_exports_file" >/dev/null 2>&1; then
        printf '%s drifted\n' "$label" >&2
        printf 'expected:\n' >&2
        cat "$native_names_file" >&2
        printf 'actual:\n' >&2
        cat "$native_exports_file" >&2
        fail=1
    fi
}

check_textmate_edge() {
    file=$1
    include=$2
    scope_file=$3
    scope=$4
    if ! grep -q "\"include\"[[:space:]]*:[[:space:]]*\"$include\"" "$file"; then
        printf 'missing external TextMate include edge %s in %s\n' "$include" "$file" >&2
        fail=1
    fi
    if ! grep -q "\"scopeName\"[[:space:]]*:[[:space:]]*\"$scope\"" "$scope_file"; then
        printf 'missing external TextMate target scope %s in %s\n' "$scope" "$scope_file" >&2
        fail=1
    fi
}

check_textmate_plist_edge() {
    file=$1
    include=$2
    scope_file=$3
    scope=$4
    if ! grep -q "<string>$include</string>" "$file"; then
        printf 'missing external TextMate plist include edge %s in %s\n' "$include" "$file" >&2
        fail=1
    fi
    if ! grep -q "<string>$scope</string>" "$scope_file"; then
        printf 'missing external TextMate plist target scope %s in %s\n' "$scope" "$scope_file" >&2
        fail=1
    fi
}

check_sublime_extends() {
    file=$1
    parent=$2
    parent_file=$3
    parent_scope=$4
    if ! grep -q "^extends:[[:space:]]*$parent" "$file"; then
        printf 'missing external Sublime extends edge %s in %s\n' "$parent" "$file" >&2
        fail=1
    fi
    if ! grep -q "^scope:[[:space:]]*$parent_scope" "$parent_file"; then
        printf 'missing external Sublime parent scope %s in %s\n' "$parent_scope" "$parent_file" >&2
        fail=1
    fi
}

check_sublime_extends_value() {
    file=$1
    parent=$2
    parent_file=$3
    parent_scope=$4
    if ! sublime_extends_values_for_file "$file" | grep -qx "$parent"; then
        printf 'missing Sublime extends edge %s in %s\n' "$parent" "$file" >&2
        fail=1
    fi
    if ! grep -q "^scope:[[:space:]]*$parent_scope" "$parent_file"; then
        printf 'missing Sublime parent scope %s in %s\n' "$parent_scope" "$parent_file" >&2
        fail=1
    fi
}

sublime_extends_values_for_file() {
    sublime_extends_values_for_stream <"$1" 2>/dev/null
}

sublime_extends_values_for_stream() {
    awk '
        /^extends:[[:space:]]*/ {
            in_list = 0
            value = $0
            sub(/^extends:[[:space:]]*/, "", value)
            if (value != "") {
                print value
            } else {
                in_list = 1
            }
            next
        }
        in_list {
            if ($0 ~ /^[[:space:]]*-[[:space:]]*/) {
                value = $0
                sub(/^[[:space:]]*-[[:space:]]*/, "", value)
                print value
                next
            }
            in_list = 0
        }
    ' |
        sed "s/^['\"]//; s/['\"]$//"
}

check_count "native .zhl grammars" 26 "$(find grammars -maxdepth 1 -type f -name '*.zhl' | wc -l)"
check_count "native .zhlb packs" 26 "$(find grammars -maxdepth 1 -type f -name '*.zhlb' | wc -l)"
check_count "TextMate JSON grammars" 271 "$(find "$(corpus_path grammars/textmate)" -maxdepth 1 -type f -name '*.tmLanguage.json' | wc -l)"
check_count "TextMate generated packs" 271 "$(find "$(corpus_path grammars/textmate-packs)" -maxdepth 1 -type f -name '*.zhlb' | wc -l)"
check_count "Sublime source chunks" 212 "$(find "$(corpus_path grammars/sublime)" -maxdepth 1 -type f -name '*.sublime-syntax.part*' | wc -l)"
check_count "Sublime source syntaxes" 113 "$(unique_sublime_sources "$(corpus_path grammars/sublime)")"
check_count "Sublime generated packs" 113 "$(find "$(corpus_path grammars/sublime-packs)" -maxdepth 1 -type f -name '*.zhlb' | wc -l)"
check_count "Sublime extends edges" 42 "$(sublime_extends_count "$(corpus_path grammars/sublime)")"
check_count "Sublime extends targets" 25 "$(sublime_extends_targets "$(corpus_path grammars/sublime)")"
check_count "Sublime syntax include edges" 38 "$(sublime_syntax_include_count "$(corpus_path grammars/sublime)")"
check_count "Sublime syntax include targets" 19 "$(sublime_syntax_include_targets "$(corpus_path grammars/sublime)")"
check_count "external Sublime fixture chunks" 52 "$(find "$(corpus_path tests/fixtures/sublime_external)" -maxdepth 1 -type f -name '*.sublime-syntax.part*' | wc -l)"
check_count "external Sublime fixture syntaxes" 19 "$(unique_sublime_sources "$(corpus_path tests/fixtures/sublime_external)")"
check_count "external Sublime extends edges" 3 "$(sublime_extends_count "$(corpus_path tests/fixtures/sublime_external)")"
check_count "external Sublime extends targets" 3 "$(sublime_extends_targets "$(corpus_path tests/fixtures/sublime_external)")"
check_count "external TextMate fixture chunks" 109 "$(find "$(corpus_path tests/fixtures/textmate_external)" -maxdepth 1 -type f -name '*.tmLanguage.json.part*' | wc -l)"
check_count "external TextMate fixture syntaxes" 40 "$(unique_textmate_sources "$(corpus_path tests/fixtures/textmate_external)")"
check_count "external TextMate plist fixtures" 8 "$(find "$(corpus_path tests/fixtures/textmate_plist_external)" -maxdepth 1 -type f -name '*.tmLanguage' ! -name 'host.tmLanguage' ! -name 'embedded.tmLanguage' | wc -l)"

native_grammar_names >"$native_names_file"
native_exports >"$native_exports_file"
if ! diff -u "$native_names_file" "$native_exports_file" >/dev/null 2>&1; then
    printf 'native grammar exports drifted; src/grammars/root.zig must expose every grammars/*.zhl route\n' >&2
    printf 'grammars/*.zhl:\n' >&2
    cat "$native_names_file" >&2
    printf 'src/grammars/root.zig exports:\n' >&2
    cat "$native_exports_file" >&2
    fail=1
fi

check_name_set "native pack/source names" "native_grammar_names" "native_pack_names"
check_name_set "TextMate pack/source names" "textmate_source_names" "textmate_pack_names"
check_name_set "Sublime pack/source names" "sublime_source_names" "sublime_pack_names"
check_name_set "external TextMate fixture names" "expected_external_textmate_fixture_names" "external_textmate_fixture_names"
check_name_set "external TextMate plist fixture names" "expected_external_textmate_plist_fixture_names" "external_textmate_plist_fixture_names"
check_name_set "external Sublime fixture names" "expected_external_sublime_fixture_names" "external_sublime_fixture_names"

check_textmate_edge "$(corpus_path tests/fixtures/textmate_external/XML.tmLanguage.json.part00)" source.java "$(corpus_path tests/fixtures/textmate_external/Java.tmLanguage.json.part00)" source.java
check_textmate_edge "$(corpus_path tests/fixtures/textmate_external/GitCommit.tmLanguage.json.part00)" source.diff "$(corpus_path tests/fixtures/textmate_external/Diff.tmLanguage.json.part00)" source.diff
check_textmate_edge "$(corpus_path tests/fixtures/textmate_external/GitRebase.tmLanguage.json.part00)" source.shell "$(corpus_path tests/fixtures/textmate_external/Shell.tmLanguage.json.part00)" source.shell
check_textmate_edge "$(corpus_path tests/fixtures/textmate_external/ShaderLab.tmLanguage.json.part00)" source.hlsl "$(corpus_path tests/fixtures/textmate_external/HLSL.tmLanguage.json.part00)" source.hlsl
check_textmate_edge "$(corpus_path tests/fixtures/textmate_external/TeX.tmLanguage.json.part00)" source.r "$(corpus_path tests/fixtures/textmate_external/R.tmLanguage.json.part00)" source.r
check_textmate_edge "$(corpus_path tests/fixtures/textmate_external/XSL.tmLanguage.json.part00)" text.xml "$(corpus_path tests/fixtures/textmate_external/XML.tmLanguage.json.part00)" text.xml
check_textmate_edge "$(corpus_path tests/fixtures/textmate_external/SCSS.tmLanguage.json.part01)" source.sassdoc "$(corpus_path tests/fixtures/textmate_external/SassDoc.tmLanguage.json.part00)" source.sassdoc
check_textmate_edge "$(corpus_path tests/fixtures/textmate_external/SCSS.tmLanguage.json.part00)" 'source.css#media-features' "$(corpus_path tests/fixtures/textmate_external/CSS.tmLanguage.json.part00)" source.css
check_textmate_edge "$(corpus_path tests/fixtures/textmate_external/SassDoc.tmLanguage.json.part00)" source.css.scss "$(corpus_path tests/fixtures/textmate_external/SCSS.tmLanguage.json.part00)" source.css.scss
check_textmate_edge "$(corpus_path tests/fixtures/textmate_external/SassDoc.tmLanguage.json.part00)" source.js "$(corpus_path tests/fixtures/textmate_external/JavaScript.tmLanguage.json.part00)" source.js
check_textmate_edge "$(corpus_path tests/fixtures/textmate_external/HTML.tmLanguage.json.part02)" source.css "$(corpus_path tests/fixtures/textmate_external/CSS.tmLanguage.json.part00)" source.css
check_textmate_edge "$(corpus_path tests/fixtures/textmate_external/HTML.tmLanguage.json.part00)" source.js "$(corpus_path tests/fixtures/textmate_external/JavaScript.tmLanguage.json.part00)" source.js
check_textmate_edge "$(corpus_path tests/fixtures/textmate_external/HTML.tmLanguage.json.part02)" text.html.basic "$(corpus_path tests/fixtures/textmate_external/HTML.tmLanguage.json.part00)" text.html.basic
check_textmate_plist_edge "$(corpus_path tests/fixtures/textmate_plist_external/GitCommit.tmLanguage)" source.diff "$(corpus_path tests/fixtures/textmate_plist_external/Diff.tmLanguage)" source.diff
check_sublime_extends_value "$(corpus_path grammars/sublime/TSX.sublime-syntax.part00)" JSX.sublime-syntax "$(corpus_path grammars/sublime/JSX.sublime-syntax.part00)" source.jsx
check_sublime_extends_value "$(corpus_path grammars/sublime/TSX.sublime-syntax.part00)" TypeScript.sublime-syntax "$(corpus_path grammars/sublime/TypeScript.sublime-syntax.part00)" source.ts
check_sublime_extends "$(corpus_path tests/fixtures/sublime_external/Diff.sublime-syntax.part00)" "Diff (Basic).sublime-syntax" "$(corpus_path "tests/fixtures/sublime_external/Diff (Basic).sublime-syntax.part00")" source.diff.basic
check_sublime_extends "$(corpus_path tests/fixtures/sublime_external/HTML.sublime-syntax.part00)" "HTML (Plain).sublime-syntax" "$(corpus_path "tests/fixtures/sublime_external/HTML (Plain).sublime-syntax.part00")" text.html.plain
check_sublime_extends "$(corpus_path tests/fixtures/sublime_external/TypeScript.sublime-syntax.part00)" JavaScript.sublime-syntax "$(corpus_path tests/fixtures/sublime_external/JavaScript.sublime-syntax.part00)" source.js

exit "$fail"
