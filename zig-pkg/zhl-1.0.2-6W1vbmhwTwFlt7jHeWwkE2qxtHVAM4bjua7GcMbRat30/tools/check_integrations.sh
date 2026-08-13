#!/usr/bin/env sh
set -eu

phase=all
case "${1:-}" in
    all|native|native-smoke|native-grammar|native-parallel|fixtures|sublime-external|sublime-external-grammar|sublime-external-parallel|sublime-packaged|sublime-packaged-grammar|sublime-packaged-parallel|themes|textmate-external|textmate-external-grammar|textmate-external-parallel|textmate-packaged|textmate-packaged-grammar|textmate-packaged-parallel)
        phase=$1
        shift
        ;;
esac
subject=
case "$phase" in
    native-grammar|sublime-external-grammar|sublime-packaged-grammar|textmate-external-grammar|textmate-packaged-grammar)
        subject=${1:?missing integration subject}
        shift
        ;;
esac
zhlc=${ZHLC:-${1:-zig-out/bin/zhlc}}
zig_cache_root=${TMPDIR:-/tmp}/zhl-integration-cache.$$
if [ -n "${ZHL_INTEGRATION_GLOBAL_CACHE_ROOT:-}" ]; then
    zig_global_cache_root=$ZHL_INTEGRATION_GLOBAL_CACHE_ROOT
    zig_global_cache_owner=0
else
    zig_global_cache_root=${TMPDIR:-/tmp}/zhl-integration-global-cache.$$
    ZHL_INTEGRATION_GLOBAL_CACHE_ROOT=$zig_global_cache_root
    export ZHL_INTEGRATION_GLOBAL_CACHE_ROOT
    zig_global_cache_owner=1
fi
tmp_root="$zig_cache_root/out"
corpus_cache=${ZHL_CORPUS_CACHE:-.zig-cache/zhl-corpus}
cleanup() {
    rm -rf "$zig_cache_root"
    if [ "$zig_global_cache_owner" -eq 1 ]; then
        rm -rf "$zig_global_cache_root"
    fi
}
trap cleanup EXIT INT TERM

prepare_corpus_cache() {
    if [ "${ZHL_CORPUS_READY:-}" = 1 ]; then
        return
    fi
    sh tools/fetch_corpus_cache.sh >/dev/null
    ZHL_CORPUS_CACHE=$corpus_cache
    ZHL_CORPUS_READY=1
    export ZHL_CORPUS_CACHE ZHL_CORPUS_READY
}

corpus_path() {
    printf '%s/%s\n' "$corpus_cache" "$1"
}

require_zhlc() {
    if [ ! -x "$zhlc" ]; then
        printf 'missing zhlc at %s; run zig build -Doptimize=ReleaseFast first\n' "$zhlc" >&2
        exit 1
    fi
}

assert_missing_zero() {
    report=$("$@")
    printf '%s\n' "$report"
    case " $report " in
        *" missing=0 "*) ;;
        *)
            printf 'missing TextMate pattern support: %s\n' "$report" >&2
            exit 1
            ;;
    esac
    case "$report" in
        *"external_missing=0"*|*"external_missing="*) ;;
        *)
            return 0
            ;;
    esac
    case "$report" in
        *"external_missing=0"*) ;;
        *)
            printf 'missing TextMate external scope support: %s\n' "$report" >&2
            exit 1
            ;;
    esac
}

assert_json_report_zero() {
    report=$("$@")
    printf '%s\n' "$report"
    case "$report" in
        *'"missing":0'*) ;;
        *)
            printf 'JSON report has unsupported patterns: %s\n' "$report" >&2
            exit 1
            ;;
    esac
    case "$report" in
        *'"skipped":0'*) ;;
        *)
            printf 'JSON report has skipped executable rules: %s\n' "$report" >&2
            exit 1
            ;;
    esac
    case "$report" in
        *'"accepted_divergence":0'*) ;;
        *)
            printf 'JSON report is missing accepted divergence count: %s\n' "$report" >&2
            exit 1
            ;;
    esac
}

assert_contains() {
    haystack=$1
    needle=$2
    label=$3
    case "$haystack" in
        *"$needle"*) ;;
        *)
            printf 'missing %s in renderer output\n' "$label" >&2
            exit 1
            ;;
    esac
}

assert_reject_contains() {
    needle=$1
    label=$2
    shift 2
    log="$tmp_root/${label}.err"
    mkdir -p "$tmp_root"
    if "$@" >"$tmp_root/${label}.out" 2>"$log"; then
        printf 'expected rejection for %s\n' "$label" >&2
        cat "$tmp_root/${label}.out" >&2
        exit 1
    fi
    if ! grep -F "$needle" "$log" >/dev/null; then
        printf 'missing rejection diagnostic for %s\n' "$label" >&2
        cat "$log" >&2
        exit 1
    fi
}

check_generated_zig() {
    log="$tmp_root/zhl-generated-test.log"
    mkdir -p "$tmp_root"
    mkdir -p "$zig_cache_root/local" "$zig_global_cache_root/global"
    if ! zig build-lib -fno-emit-bin --cache-dir "$zig_cache_root/local" --global-cache-dir "$zig_global_cache_root/global" --dep zhl -Mroot="$1" -Mzhl=src/root.zig >"$log" 2>&1; then
        cat "$log" >&2
        rm -f "$log"
        exit 1
    fi
    rm -f "$log"
}

integration_jobs() {
    if [ -n "${ZHL_INTEGRATION_JOBS:-}" ]; then
        printf '%s\n' "$ZHL_INTEGRATION_JOBS"
        return
    fi
    cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || printf '8')
    case "$cpus" in
        ''|*[!0-9]*) cpus=8 ;;
    esac
    jobs=$((cpus * 2))
    [ "$jobs" -lt 8 ] && jobs=8
    [ "$jobs" -gt 64 ] && jobs=64
    printf '%s\n' "$jobs"
}

fixture_for_visual_grammar() {
    case "$1" in
        bash) printf '%s\n' tests/fixtures/languages/bash-textmate.sh ;;
        c) printf '%s\n' tests/fixtures/languages/c-textmate.c ;;
        cpp) printf '%s\n' tests/fixtures/languages/cpp-textmate.cpp ;;
        csharp) printf '%s\n' tests/fixtures/languages/csharp-textmate.cs ;;
        css) printf '%s\n' tests/fixtures/languages/css-textmate.css ;;
        go) printf '%s\n' tests/fixtures/languages/go-textmate.go ;;
        html) printf '%s\n' tests/fixtures/languages/html-textmate.html ;;
        java) printf '%s\n' tests/fixtures/languages/java-textmate.java ;;
        javascript) printf '%s\n' tests/fixtures/languages/javascript-textmate.js ;;
        jsx) printf '%s\n' tests/fixtures/languages/jsx-textmate.jsx ;;
        json) printf '%s\n' tests/fixtures/languages/json-textmate.json ;;
        kotlin) printf '%s\n' tests/fixtures/languages/kotlin-textmate.kt ;;
        markdown) printf '%s\n' tests/fixtures/languages/markdown-textmate.md ;;
        php) printf '%s\n' tests/fixtures/languages/php-textmate.php ;;
        python) printf '%s\n' tests/fixtures/languages/python-textmate.py ;;
        ruby) printf '%s\n' tests/fixtures/languages/ruby-textmate.rb ;;
        rust) printf '%s\n' tests/fixtures/languages/rust-textmate.rs ;;
        sql) printf '%s\n' tests/fixtures/languages/sql-textmate.sql ;;
        swift) printf '%s\n' tests/fixtures/languages/swift-textmate.swift ;;
        toml) printf '%s\n' tests/fixtures/languages/toml-textmate.toml ;;
        tsx) printf '%s\n' tests/fixtures/languages/tsx-textmate.tsx ;;
        typescript) printf '%s\n' tests/fixtures/languages/typescript-textmate.ts ;;
        xml) printf '%s\n' tests/fixtures/languages/xml-textmate.xml ;;
        yaml) printf '%s\n' tests/fixtures/languages/yaml-textmate.yaml ;;
        zig) printf '%s\n' tests/fixtures/languages/zig-textmate.zig ;;
        zig_0_16) printf '%s\n' tests/fixtures/languages/zig-textmate.zig ;;
        *) return 1 ;;
    esac
}

check_converted_native() {
    label=$1
    out="$tmp_root/${label}.zhl"
    zig_out="$tmp_root/${label}.zig"
    shift
    mkdir -p "$tmp_root"
    convert_zhlc=$1
    convert_command=$2
    convert_source=$3
    shift 4
    converted_output=$("$convert_zhlc" "$convert_command" "$convert_source" "$out" "$@")
    converted_native_out=$out
    printf '%s\n' "$converted_output"
    case "$converted_output" in
        *"converted=0 "*)
            printf 'conversion emitted no native rules: %s\n' "$converted_output" >&2
            exit 1
            ;;
    esac
    case " $converted_output " in
        *" skipped=0 "*) ;;
        *)
            printf 'conversion skipped executable rules: %s\n' "$converted_output" >&2
            exit 1
            ;;
    esac
    "$zhlc" check-native "$out"
    "$zhlc" compile-native "$out" "$zig_out"
    check_generated_zig "$zig_out"
}

run_parallel_files() {
    dir=$1
    name=$2
    worker_phase=$3
    [ -d "$dir" ] || return 0
    jobs=$(integration_jobs)
    count=$(find "$dir" -maxdepth 1 -type f -name "$name" -print | wc -l | tr -d ' ')
    [ "$count" -eq 0 ] && return 0
    log_dir="$zig_cache_root/logs-${worker_phase}"
    mkdir -p "$log_dir"
    find "$dir" -maxdepth 1 -type f -name "$name" -print0 |
        xargs -0 -r -n 1 -P "$jobs" sh -c '
            phase=$1
            zhlc=$2
            log_dir=$3
            subject=$4
            base=${subject##*/}
            log="$log_dir/$base.log"
            if sh tools/check_integrations.sh "$phase" "$subject" "$zhlc" >"$log" 2>&1; then
                exit 0
            fi
            printf "integration failed: %s\n" "$subject" >&2
            cat "$log" >&2
            exit 1
        ' sh "$worker_phase" "$zhlc" "$log_dir"
    printf 'integration phase %s ok: %s files\n' "$worker_phase" "$count"
}

run_parallel_phases() {
    log_dir="$zig_cache_root/logs-all"
    mkdir -p "$log_dir"
    pids=
    for subphase in "$@"; do
        printf 'integration phase %s started\n' "$subphase"
        ( sh tools/check_integrations.sh "$subphase" "$zhlc" >"$log_dir/$subphase.log" 2>&1 ) &
        pids="$pids $!"
    done
    status=0
    for pid in $pids; do
        wait "$pid" || status=1
    done
    total=0
    for subphase in "$@"; do
        cat "$log_dir/$subphase.log"
        count=$(sed -n 's/^integration phase .* ok: \([0-9][0-9]*\) files$/\1/p' "$log_dir/$subphase.log" | awk '{ total += $1 } END { print total + 0 }')
        total=$((total + count))
    done
    printf 'integration checks ok: %s grammar files plus smoke, fixture, and theme suites\n' "$total"
    [ "$status" -eq 0 ] || exit "$status"
}

external_sublime_names() {
    dir=$(corpus_path tests/fixtures/sublime_external)
    find "$dir" -maxdepth 1 -type f -name '*.sublime-syntax.part00' |
        while IFS= read -r path; do
            base=${path##*/}
            printf '%s\n' "${base%.sublime-syntax.part00}"
        done |
        sort
}

external_textmate_names() {
    dir=$(corpus_path tests/fixtures/textmate_external)
    find "$dir" -maxdepth 1 -type f -name '*.tmLanguage.json.part00' |
        while IFS= read -r path; do
            base=${path##*/}
            printf '%s\n' "${base%.tmLanguage.json.part00}"
        done |
        sort
}

run_parallel_external_sublime() {
    jobs=$(integration_jobs)
    count=$(external_sublime_names | wc -l | tr -d ' ')
    log_dir="$zig_cache_root/logs-sublime-external"
    mkdir -p "$log_dir"
    external_sublime_names |
        tr '\n' '\0' |
        xargs -0 -r -n 1 -P "$jobs" sh -c '
            phase=$1
            zhlc=$2
            log_dir=$3
            subject=$4
            log="$log_dir/$subject.log"
            if sh tools/check_integrations.sh "$phase" "$subject" "$zhlc" >"$log" 2>&1; then
                exit 0
            fi
            printf "integration failed: external Sublime %s\n" "$subject" >&2
            cat "$log" >&2
            exit 1
        ' sh sublime-external-grammar "$zhlc" "$log_dir"
    printf 'integration phase sublime-external-grammar ok: %s files\n' "$count"
}

check_external_sublime() {
    external_sublime_names | while IFS= read -r name; do
        check_external_sublime_grammar "$name"
    done
}

check_external_sublime_grammar() {
    name=$1
    dir=$(corpus_path tests/fixtures/sublime_external)
    mkdir -p "$zig_cache_root"
    for first in "$dir"/*.sublime-syntax.part00; do
        [ -e "$first" ] || continue
        base=${first##*/}
        base=${base%.sublime-syntax.part00}
        cat "$dir/${base}.sublime-syntax.part"* > "$zig_cache_root/${base}.sublime-syntax"
    done
    source="$zig_cache_root/${name}.sublime-syntax"
    cat "$dir/${name}.sublime-syntax.part"* > "$source"
    "$zhlc" check-sublime "$source"
    assert_missing_zero "$zhlc" report-sublime "$source"
    check_converted_native "converted-sublime-external-${name}" "$zhlc" convert-sublime "$source" "/tmp/converted-sublime-external-${name}.zhl"
}

run_parallel_external_textmate() {
    jobs=$(integration_jobs)
    count=$(external_textmate_names | wc -l | tr -d ' ')
    log_dir="$zig_cache_root/logs-textmate-external"
    mkdir -p "$log_dir"
    external_textmate_names |
        tr '\n' '\0' |
        xargs -0 -r -n 1 -P "$jobs" sh -c '
            phase=$1
            zhlc=$2
            log_dir=$3
            subject=$4
            log="$log_dir/$subject.log"
            if sh tools/check_integrations.sh "$phase" "$subject" "$zhlc" >"$log" 2>&1; then
                exit 0
            fi
            printf "integration failed: external TextMate %s\n" "$subject" >&2
            cat "$log" >&2
            exit 1
        ' sh textmate-external-grammar "$zhlc" "$log_dir"
    printf 'integration phase textmate-external-grammar ok: %s files\n' "$count"
}

check_external_textmate() {
    external_textmate_names | while IFS= read -r name; do
        check_external_textmate_grammar "$name"
    done
}

check_external_textmate_grammar() {
    name=$1
    dir=$(corpus_path tests/fixtures/textmate_external)
    mkdir -p "$zig_cache_root/textmate-external"
    for first in "$dir"/*.tmLanguage.json.part00; do
        [ -e "$first" ] || continue
        base=${first##*/}
        base=${base%.tmLanguage.json.part00}
        cat "$dir/${base}.tmLanguage.json.part"* > "$zig_cache_root/textmate-external/${base}.tmLanguage.json"
    done
    source="$zig_cache_root/textmate-external/${name}.tmLanguage.json"
    "$zhlc" check-textmate-json "$source" --include-dir "$zig_cache_root/textmate-external"
    assert_missing_zero "$zhlc" report-textmate-json "$source" --skipped --include-dir "$zig_cache_root/textmate-external"
    check_converted_native "converted-textmate-external-${name}" "$zhlc" convert-textmate-json "$source" "/tmp/converted-textmate-external-${name}.zhl" --include-dir "$zig_cache_root/textmate-external"
}

check_packaged_sublime() {
    dir=$(corpus_path grammars/sublime)
    [ -d "$dir" ] || return 0
    source_dir="$zig_cache_root/sublime"
    assemble_sublime_package_dir "$source_dir" "$dir"
    ZHL_SUBLIME_SOURCE_DIR=$source_dir
    export ZHL_SUBLIME_SOURCE_DIR
    for first in "$dir"/*.sublime-syntax.part00; do
        [ -e "$first" ] || continue
        check_packaged_sublime_grammar "$first"
    done
    unset ZHL_SUBLIME_SOURCE_DIR
}

assemble_sublime_package_dir() {
    out_dir=$1
    dir=$2
    mkdir -p "$out_dir"
    for first_part in "$dir"/*.sublime-syntax.part00; do
        [ -e "$first_part" ] || continue
        sibling=${first_part##*/}
        sibling=${sibling%.sublime-syntax.part00}
        cat "$dir/${sibling}.sublime-syntax.part"* > "$out_dir/${sibling}.sublime-syntax"
    done
}

check_packaged_sublime_grammar() {
    first=$1
    dir=${first%/*}
    pack_dir=grammars/sublime-packs
    base=${first##*/}
    base=${base%.sublime-syntax.part00}
    lang=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
    mkdir -p "$tmp_root"
    source_dir=${ZHL_SUBLIME_SOURCE_DIR:-$tmp_root/sublime}
    [ -n "${ZHL_SUBLIME_SOURCE_DIR:-}" ] || assemble_sublime_package_dir "$source_dir" "$dir"
    source="$source_dir/${base}.sublime-syntax"
    pack="$tmp_root/converted-sublime-packaged-${lang}.zhlb"
    tracked_pack="$pack_dir/${lang}.zhlb"
    "$zhlc" check-sublime "$source"
    assert_missing_zero "$zhlc" report-sublime "$source"
    check_converted_native "converted-sublime-packaged-${base}" "$zhlc" convert-sublime "$source" "$tmp_root/converted-sublime-packaged-${base}.zhl"
    "$zhlc" pack-native "$converted_native_out" "$pack" >/dev/null
    "$zhlc" check-zhlb "$pack" >/dev/null
    if [ ! -f "$tracked_pack" ]; then
        printf 'missing tracked Sublime pack %s\n' "$tracked_pack" >&2
        exit 1
    fi
    if ! cmp -s "$pack" "$tracked_pack"; then
        printf 'stale Sublime pack %s; run tools/update_sublime_packs.sh\n' "$tracked_pack" >&2
        exit 1
    fi
}

check_native_smoke() {
    "$zhlc" check-native grammars/zig_0_16.zhl
    "$zhlc" dump-ir grammars/zig_0_16.zhl >/dev/null
    "$zhlc" dump tests/golden/zig_basic.input.zig --grammar zig >/dev/null
    html=$("$zhlc" render-html tests/golden/zig_basic.input.zig --grammar zig)
    assert_contains "$html" '<span class="zhl-keyword">const</span>' "HTML keyword span"
    ansi=$("$zhlc" render-ansi tests/golden/zig_basic.input.zig --grammar zig)
    esc=$(printf '\033')
    assert_contains "$ansi" "${esc}[35mconst" "ANSI keyword span"
    "$zhlc" dump tests/fixtures/languages/bash-textmate.sh --grammar sh >/dev/null
    "$zhlc" dump tests/fixtures/languages/bash-textmate.sh --grammar shell >/dev/null
    "$zhlc" dump tests/fixtures/languages/cpp-textmate.cpp --grammar cc >/dev/null
    "$zhlc" dump tests/fixtures/languages/cpp-textmate.cpp --grammar 'c++' >/dev/null
    "$zhlc" dump tests/fixtures/languages/csharp-textmate.cs --grammar cs >/dev/null
    "$zhlc" dump tests/fixtures/languages/javascript-textmate.js --grammar js >/dev/null
    "$zhlc" dump tests/fixtures/languages/javascript-textmate.js --grammar mjs >/dev/null
    "$zhlc" dump tests/fixtures/languages/javascript-textmate.js --grammar cjs >/dev/null
    "$zhlc" dump tests/fixtures/languages/typescript-textmate.ts --grammar ts >/dev/null
    "$zhlc" dump tests/fixtures/languages/typescript-textmate.ts --grammar mts >/dev/null
    "$zhlc" dump tests/fixtures/languages/typescript-textmate.ts --grammar cts >/dev/null
    "$zhlc" dump tests/fixtures/languages/python-textmate.py --grammar py >/dev/null
    "$zhlc" dump tests/fixtures/languages/python-textmate.py --grammar pyw >/dev/null
    "$zhlc" dump tests/fixtures/languages/markdown-textmate.md --grammar md >/dev/null
    "$zhlc" dump tests/fixtures/languages/yaml-textmate.yaml --grammar yml >/dev/null
    "$zhlc" dump tests/golden/zig_basic.input.zig --grammar zig_0_16 >/dev/null
}

check_native() {
    check_native_smoke
    for grammar in grammars/*.zhl; do
        check_native_grammar "$grammar"
    done
}

check_native_parallel() {
    run_parallel_files grammars '*.zhl' native-grammar
}

check_native_grammar() {
    grammar=$1
    name=${grammar##*/}
    name=${name%.zhl}
    mkdir -p "$tmp_root"
    out="$tmp_root/${name}.zig"
    out_zhlb="$tmp_root/${name}.zhlb"
    tracked_zhlb=${grammar%.zhl}.zhlb
    tracked_zig="src/grammars/${name}.zig"
    if [ "$name" = "zig_0_16" ]; then
        tracked_zig=src/grammars/zig_0_16_generated.zig
    fi
    "$zhlc" check-native "$grammar"
    "$zhlc" pack-native "$grammar" "$out_zhlb"
    "$zhlc" check-zhlb "$out_zhlb"
    if [ ! -f "$tracked_zhlb" ]; then
        printf 'missing tracked native pack %s\n' "$tracked_zhlb" >&2
        exit 1
    fi
    if ! cmp -s "$out_zhlb" "$tracked_zhlb"; then
        printf 'stale native pack %s; regenerate from %s\n' "$tracked_zhlb" "$grammar" >&2
        exit 1
    fi
    "$zhlc" compile-native "$grammar" "$out"
    if [ ! -f "$tracked_zig" ]; then
        printf 'missing tracked generated grammar %s\n' "$tracked_zig" >&2
        exit 1
    fi
    if ! cmp -s "$out" "$tracked_zig"; then
        printf 'stale generated grammar %s; regenerate from %s\n' "$tracked_zig" "$grammar" >&2
        exit 1
    fi
    check_generated_zig "$out"
    fixture=$(fixture_for_visual_grammar "$name") || return 0
    "$zhlc" dump "$fixture" --grammar "$name" >/dev/null
    html=$("$zhlc" render-html "$fixture" --grammar "$name")
    assert_contains "$html" '<span class="zhl-' "$name native HTML span"
    case "$name" in
        rust) assert_contains "$html" '<span class="zhl-comment">/* outer /* inner */ still */</span>' "$name native nested block comment span" ;;
        c|javascript|typescript) assert_contains "$html" '<span class="zhl-comment">/* block comment */</span>' "$name native block comment span" ;;
    esac
    ansi=$("$zhlc" render-ansi "$fixture" --grammar "$name")
    esc=$(printf '\033')
    assert_contains "$ansi" "${esc}[" "$name native ANSI span"
}

check_fixtures() {
    bad_json="$tmp_root/malformed-textmate.json"
    bad_plist="$tmp_root/malformed-textmate.tmLanguage"
    mkdir -p "$tmp_root"
    printf '%s\n' '{"scopeName":"source.bad","patterns":{}}' >"$bad_json"
    printf '%s\n' '<plist><dict><key>scopeName</key><string>source.bad</string></dict></plist>' >"$bad_plist"
    assert_reject_contains 'MalformedGrammar' malformed-textmate-json "$zhlc" check-textmate-json "$bad_json"
    assert_reject_contains 'MalformedGrammar' malformed-textmate-plist "$zhlc" check-textmate-plist "$bad_plist"

    for grammar in tests/fixtures/textmate_string.json tests/fixtures/textmate_injections.json tests/fixtures/textmate_while.json; do
        "$zhlc" check-textmate-json "$grammar"
        assert_missing_zero "$zhlc" report-textmate-json "$grammar"
        assert_json_report_zero "$zhlc" report-textmate-json "$grammar" --json
        base=${grammar##*/}
        check_converted_native "converted-${base%.json}" "$zhlc" convert-textmate-json "$grammar" "/tmp/converted-${base%.json}.zhl"
    done
    embedded=tests/fixtures/textmate_embedded.json
    "$zhlc" check-textmate-json "$embedded"
    assert_missing_zero "$zhlc" report-textmate-json "$embedded"
    check_converted_native "converted-textmate-embedded" "$zhlc" convert-textmate-json "$embedded" /tmp/converted-textmate-embedded.zhl
    external_host=tests/fixtures/textmate_external_host.json
    external_embedded=tests/fixtures/textmate_external_embedded.json
    "$zhlc" check-textmate-json "$external_host" --include-grammar "$external_embedded"
    "$zhlc" check-textmate-json "$external_embedded"
    check_converted_native "converted-textmate-external" "$zhlc" convert-textmate-json "$external_host" /tmp/converted-textmate-external.zhl --include-grammar "$external_embedded"
    plist_external_host=tests/fixtures/textmate_plist_external/host.tmLanguage
    plist_external_embedded=tests/fixtures/textmate_plist_external/embedded.tmLanguage
    "$zhlc" check-textmate-plist "$plist_external_host" --include-grammar "$plist_external_embedded"
    "$zhlc" check-textmate-plist "$plist_external_embedded"
    assert_missing_zero "$zhlc" report-textmate-plist "$plist_external_host" --skipped --include-grammar "$plist_external_embedded"
    check_converted_native "converted-textmate-plist-external" "$zhlc" convert-textmate-plist "$plist_external_host" /tmp/converted-textmate-plist-external.zhl --include-grammar "$plist_external_embedded"
    plist_dir=$(corpus_path tests/fixtures/textmate_plist_external)
    for grammar in "$plist_dir"/*.tmLanguage; do
        base=${grammar##*/}
        case "$base" in
            host.tmLanguage|embedded.tmLanguage) continue ;;
        esac
        cached_grammar="$plist_dir/$base"
        "$zhlc" check-textmate-plist "$cached_grammar" --include-dir "$plist_dir"
        assert_missing_zero "$zhlc" report-textmate-plist "$cached_grammar" --skipped --include-dir "$plist_dir"
        check_converted_native "converted-textmate-plist-external-${base%.tmLanguage}" "$zhlc" convert-textmate-plist "$cached_grammar" "/tmp/converted-textmate-plist-external-${base%.tmLanguage}.zhl" --include-dir "$plist_dir"
    done
    conditional=tests/fixtures/textmate_conditional.json
    "$zhlc" check-textmate-json "$conditional"
    assert_missing_zero "$zhlc" report-textmate-json "$conditional"
    check_converted_native "converted-textmate-conditional" "$zhlc" convert-textmate-json "$conditional" /tmp/converted-textmate-conditional.zhl

    for grammar in tests/fixtures/*.tmLanguage; do
        "$zhlc" check-textmate-plist "$grammar"
        assert_missing_zero "$zhlc" report-textmate-plist "$grammar"
        assert_json_report_zero "$zhlc" report-textmate-plist "$grammar" --json
        base=${grammar##*/}
        check_converted_native "converted-${base%.tmLanguage}" "$zhlc" convert-textmate-plist "$grammar" "/tmp/converted-${base%.tmLanguage}.zhl"
    done

    for grammar in tests/fixtures/*.sublime-syntax; do
        "$zhlc" check-sublime "$grammar"
        assert_missing_zero "$zhlc" report-sublime "$grammar"
        assert_json_report_zero "$zhlc" report-sublime "$grammar" --json
        base=${grammar##*/}
        check_converted_native "converted-${base%.sublime-syntax}" "$zhlc" convert-sublime "$grammar" "/tmp/converted-${base%.sublime-syntax}.zhl"
    done
}

check_themes() {
    "$zhlc" check-theme-json tests/fixtures/theme_basic.json
    "$zhlc" check-theme-plist tests/fixtures/theme_basic.tmTheme
    mkdir -p "$tmp_root"
    "$zhlc" compile-theme-json tests/fixtures/theme_basic.json "$tmp_root/theme_json.zig"
    "$zhlc" compile-theme-plist tests/fixtures/theme_basic.tmTheme "$tmp_root/theme_plist.zig"
    check_generated_zig "$tmp_root/theme_json.zig"
    check_generated_zig "$tmp_root/theme_plist.zig"
}

check_packaged_textmate() {
    textmate_dir=$(corpus_path grammars/textmate)
    if [ -d "$textmate_dir" ]; then
        for grammar in "$textmate_dir"/*.tmLanguage.json; do
            [ -e "$grammar" ] || continue
            check_packaged_textmate_grammar "$grammar"
        done
    fi
}

check_packaged_sublime_parallel() {
    source_dir="$zig_cache_root/sublime"
    sublime_dir=$(corpus_path grammars/sublime)
    assemble_sublime_package_dir "$source_dir" "$sublime_dir"
    ZHL_SUBLIME_SOURCE_DIR=$source_dir
    export ZHL_SUBLIME_SOURCE_DIR
    run_parallel_files "$sublime_dir" '*.sublime-syntax.part00' sublime-packaged-grammar
    unset ZHL_SUBLIME_SOURCE_DIR
}

check_packaged_textmate_parallel() {
    run_parallel_files "$(corpus_path grammars/textmate)" '*.tmLanguage.json' textmate-packaged-grammar
}

check_packaged_textmate_grammar() {
    grammar=$1
    lang=${grammar##*/}
    lang=${lang%.tmLanguage.json}
    include_dir=${grammar%/*}
    assert_missing_zero "$zhlc" report-textmate-json "$grammar" --skipped --include-dir "$include_dir"
    check_converted_native "converted-${lang}" "$zhlc" convert-textmate-json "$grammar" "/tmp/converted-${lang}.zhl" --include-dir "$include_dir"
    pack="$tmp_root/converted-${lang}.zhlb"
    tracked_pack="$(corpus_path grammars/textmate-packs)/${lang}.zhlb"
    "$zhlc" pack-native "$converted_native_out" "$pack" >/dev/null
    "$zhlc" check-zhlb "$pack" >/dev/null
    if [ ! -f "$tracked_pack" ]; then
        printf 'missing tracked TextMate pack %s\n' "$tracked_pack" >&2
        exit 1
    fi
    if ! cmp -s "$pack" "$tracked_pack"; then
        printf 'stale TextMate pack %s; run tools/update_textmate_packs.sh\n' "$tracked_pack" >&2
        exit 1
    fi
}

require_zhlc
prepare_corpus_cache
case "$phase" in
    all)
        run_parallel_phases \
            native-smoke \
            native-parallel \
            fixtures \
            textmate-external-parallel \
            sublime-external-parallel \
            sublime-packaged-parallel \
            themes \
            textmate-packaged-parallel
        ;;
    native) check_native ;;
    native-smoke) check_native_smoke ;;
    native-grammar) check_native_grammar "$subject" ;;
    native-parallel) check_native_parallel ;;
    fixtures) check_fixtures ;;
    sublime-external) check_external_sublime ;;
    sublime-external-grammar) check_external_sublime_grammar "$subject" ;;
    sublime-external-parallel) run_parallel_external_sublime ;;
    sublime-packaged) check_packaged_sublime ;;
    sublime-packaged-grammar) check_packaged_sublime_grammar "$subject" ;;
    sublime-packaged-parallel) check_packaged_sublime_parallel ;;
    themes) check_themes ;;
    textmate-external) check_external_textmate ;;
    textmate-external-grammar) check_external_textmate_grammar "$subject" ;;
    textmate-external-parallel) run_parallel_external_textmate ;;
    textmate-packaged) check_packaged_textmate ;;
    textmate-packaged-grammar) check_packaged_textmate_grammar "$subject" ;;
    textmate-packaged-parallel) check_packaged_textmate_parallel ;;
    *)
        printf 'unknown integration phase: %s\n' "$phase" >&2
        exit 1
        ;;
esac
