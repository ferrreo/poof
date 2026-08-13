#!/usr/bin/env sh
set -eu

fail=0
repo_root=$PWD
cache=${ZHL_CORPUS_CACHE:-.zig-cache/zhl-corpus}

case "$cache" in
    "$PWD"|"$PWD"/*)
        case "$cache" in
            "$PWD/.zig-cache"|"$PWD/.zig-cache"/*) ;;
            *)
                printf 'ZHL_CORPUS_CACHE must not point at a tracked repo path: %s\n' "$cache" >&2
                fail=1
                ;;
        esac
        ;;
esac

if [ "$fail" -eq 0 ]; then
    if ! sh tools/fetch_corpus_cache.sh >/dev/null; then
        fail=1
    fi
fi

require_file() {
    path=$1
    if [ ! -s "$path" ]; then
        printf 'missing corpus cache artifact: %s\n' "$path" >&2
        fail=1
    fi
}

require_dir() {
    path=$1
    if [ ! -d "$path" ]; then
        printf 'missing corpus directory: %s\n' "$path" >&2
        fail=1
    fi
}

count_files() {
    dir=$1
    name=$2
    find "$dir" -maxdepth 1 -type f -name "$name" | wc -l | tr -d ' '
}

check_count() {
    label=$1
    expected=$2
    actual=$3
    if [ "$actual" != "$expected" ]; then
        printf '%s cache count drifted: got %s expected %s\n' "$label" "$actual" "$expected" >&2
        fail=1
    fi
}

require_file "$cache/manifest.json"
require_file "$cache/corpus_summary.json"
require_dir "$cache/grammars/textmate"
require_dir "$cache/grammars/textmate-packs"
require_dir "$cache/grammars/sublime"
require_dir "$cache/grammars/sublime-packs"
require_dir "$cache/tests/fixtures/textmate_external"
require_dir "$cache/tests/fixtures/textmate_plist_external"
require_dir "$cache/tests/fixtures/sublime_external"
require_dir "corpus/locks"

if ! grep -q '"version"[[:space:]]*:[[:space:]]*1' "$cache/manifest.json"; then
    printf 'corpus manifest missing version=1\n' >&2
    fail=1
fi

if ! grep -q '"source"[[:space:]]*:[[:space:]]*"current-repo-snapshot"' "$cache/manifest.json"; then
    printf 'corpus manifest must name current source snapshot until external fetch replaces vendored corpora\n' >&2
    fail=1
fi

check_count "native grammar source" 26 "$(count_files "$cache/grammars" '*.zhl')"
check_count "native grammar pack" 26 "$(count_files "$cache/grammars" '*.zhlb')"
check_count "TextMate source" 271 "$(count_files "$cache/grammars/textmate" '*.tmLanguage.json')"
check_count "TextMate pack" 271 "$(count_files "$cache/grammars/textmate-packs" '*.zhlb')"
check_count "Sublime source chunks" 212 "$(count_files "$cache/grammars/sublime" '*.sublime-syntax.part*')"
check_count "Sublime pack" 113 "$(count_files "$cache/grammars/sublime-packs" '*.zhlb')"
check_count "external TextMate chunks" 109 "$(count_files "$cache/tests/fixtures/textmate_external" '*.tmLanguage.json.part*')"
check_count "external TextMate plist" 8 "$(find "$cache/tests/fixtures/textmate_plist_external" -maxdepth 1 -type f -name '*.tmLanguage' ! -name 'host.tmLanguage' ! -name 'embedded.tmLanguage' | wc -l | tr -d ' ')"
check_count "external Sublime chunks" 52 "$(count_files "$cache/tests/fixtures/sublime_external" '*.sublime-syntax.part*')"

for lock in corpus/locks/*.sha256; do
    [ -e "$lock" ] || continue
    if ! (cd "$cache" && sha256sum -c "$repo_root/$lock" >/dev/null); then
        printf 'corpus cache hash verification failed: %s\n' "$lock" >&2
        fail=1
    fi
done

if ! ZHL_CORPUS_CACHE=$cache sh tools/check_corpus_counts.sh; then
    fail=1
fi

exit "$fail"
