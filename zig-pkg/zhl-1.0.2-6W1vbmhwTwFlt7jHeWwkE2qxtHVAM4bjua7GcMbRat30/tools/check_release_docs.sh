#!/bin/sh
set -eu

ok=1
corpus_root=${ZHL_CORPUS_CACHE:-.zig-cache/zhl-corpus}

ZHL_CORPUS_CACHE=$corpus_root sh tools/fetch_corpus_cache.sh >/dev/null

corpus_path() {
    printf '%s/%s' "$corpus_root" "$1"
}
for file in \
    docs/native_dsl.md \
    docs/public_api.md \
    docs/migration.md \
    docs/tree_sitter.md \
    docs/v1_status.md \
    docs/zhlb.md \
    docs/zig_0_16_syntax_highlighting_engine_spec.md \
    docs/spec/zig_0_16_syntax_highlighting_engine_spec_part_1.md \
    docs/spec/zig_0_16_syntax_highlighting_engine_spec_part_2.md \
    docs/spec/zig_0_16_syntax_highlighting_engine_spec_part_3.md
do
    if [ ! -s "$file" ]; then
        printf 'missing release doc: %s\n' "$file" >&2
        ok=0
    fi
done

for heading in \
    "From TextMate JSON" \
    "From TextMate plist" \
    "From Sublime Syntax" \
    "From Shiki Or vscode-textmate" \
    "From syntect" \
    "Optional Tree-sitter Overlay" \
    "Native zhl Grammars" \
    "Supported v1 Corpus Boundary" \
    "Runtime Integration"
do
    if ! grep -F "## $heading" docs/migration.md >/dev/null; then
        printf 'missing migration section: %s\n' "$heading" >&2
        ok=0
    fi
done

for part in 1 2 3; do
    target="spec/zig_0_16_syntax_highlighting_engine_spec_part_${part}.md"
    if ! grep -F "($target)" docs/zig_0_16_syntax_highlighting_engine_spec.md >/dev/null; then
        printf 'spec index missing link: %s\n' "$target" >&2
        ok=0
    fi
done

if grep -F 'quote escapes `\Q...\E` are rejected' docs/v1_status.md >/dev/null; then
    printf 'stale quote escape docs in v1 status\n' >&2
    ok=0
fi

if ! grep -F 'zig build check-tree-sitter' docs/tree_sitter.md >/dev/null ||
    ! grep -F 'zig build check-tree-sitter' docs/v1_status.md >/dev/null ||
    ! grep -F '"tree-sitter": "node tree_sitter.mjs"' benchmark/package.json >/dev/null; then
    printf 'stale Tree-sitter proof docs or package script\n' >&2
    ok=0
fi

if ! grep -Fx 'zig-pkg/' .gitignore >/dev/null; then
    printf 'missing zig-pkg/ in .gitignore\n' >&2
    ok=0
fi

native_grammars=$(find grammars -maxdepth 1 -type f -name '*.zhl' | wc -l | tr -d ' ')
native_packs=$(find grammars -maxdepth 1 -type f -name '*.zhlb' | wc -l | tr -d ' ')
textmate_grammars=$(find "$(corpus_path grammars/textmate)" -maxdepth 1 -type f -name '*.tmLanguage.json' | wc -l | tr -d ' ')
textmate_packs=$(find "$(corpus_path grammars/textmate-packs)" -maxdepth 1 -type f -name '*.zhlb' | wc -l | tr -d ' ')
sublime_chunks=$(find "$(corpus_path grammars/sublime)" -maxdepth 1 -type f -name '*.sublime-syntax.part*' | wc -l | tr -d ' ')
sublime_syntaxes=$(find "$(corpus_path grammars/sublime)" -maxdepth 1 -type f -name '*.sublime-syntax.part00' | wc -l | tr -d ' ')
sublime_packs=$(find "$(corpus_path grammars/sublime-packs)" -maxdepth 1 -type f -name '*.zhlb' | wc -l | tr -d ' ')
external_sublime_syntaxes=$(find "$(corpus_path tests/fixtures/sublime_external)" -maxdepth 1 -type f -name '*.sublime-syntax.part00' | wc -l | tr -d ' ')
if ! grep -F "Native hand-written \`.zhl\`" docs/v1_status.md >/dev/null ||
    ! grep -F "TextMate JSON: ${textmate_grammars} checked-in grammars" docs/v1_status.md >/dev/null ||
    ! grep -F "${textmate_grammars} checked-in TextMate JSON grammars" docs/migration.md >/dev/null ||
    ! grep -F "Sublime: local fixtures plus ${sublime_syntaxes} packaged upstream source syntaxes in ${sublime_chunks}" docs/v1_status.md >/dev/null ||
    ! grep -F "${external_sublime_syntaxes} external Sublime fixture syntaxes" docs/v1_status.md >/dev/null ||
    ! grep -F "${sublime_syntaxes} packaged" docs/migration.md >/dev/null ||
    [ "$native_grammars" != "$native_packs" ] ||
    [ "$textmate_grammars" != "$textmate_packs" ] ||
    [ "$sublime_syntaxes" != "$sublime_packs" ]; then
    printf 'stale corpus counts in release docs\n' >&2
    ok=0
fi

for grammar in grammars/*.zhl; do
    name=${grammar##*/}
    name=${name%.zhl}
    case "$name" in
        cpp) display='C++' ;;
        csharp) display='C#' ;;
        css) display='CSS' ;;
        html) display='HTML' ;;
        jsx) display='JSX' ;;
        php) display='PHP' ;;
        javascript) display='JavaScript' ;;
        sql) display='SQL' ;;
        toml) display='TOML' ;;
        tsx) display='TSX' ;;
        typescript) display='TypeScript' ;;
        xml) display='XML' ;;
        yaml) display='YAML' ;;
        zig_0_16) display='Zig 0.16' ;;
        *) display=$(printf '%s' "$name" | awk '{ print toupper(substr($0, 1, 1)) substr($0, 2) }') ;;
    esac
    if ! grep -F "$display" docs/v1_status.md >/dev/null; then
        printf 'missing native grammar %s in v1 status\n' "$display" >&2
        ok=0
    fi
done

onig_cases=$(sed -n 's/.*ZHL_EXPECT_ONIG_CASES ?? \([0-9][0-9]*\)).*/\1/p' benchmark/check_oniguruma_cases.mjs)
onig_generated=$(sed -n 's/.*ZHL_EXPECT_ONIG_GENERATED_CASES ?? \([0-9][0-9]*\)).*/\1/p' benchmark/check_oniguruma_cases.mjs)
onig_checked=$(sed -n 's/.*ZHL_EXPECT_ONIG_CHECKED ?? \([0-9][0-9]*\)).*/\1/p' benchmark/check_oniguruma_cases.mjs)
onig_skipped=$(sed -n 's/.*ZHL_EXPECT_ONIG_SKIPPED ?? \([0-9][0-9]*\)).*/\1/p' benchmark/check_oniguruma_cases.mjs)
if ! grep -F "parses those same ${onig_cases} Zig" docs/v1_status.md >/dev/null ||
    ! grep -F "table rows plus ${onig_generated} generated" docs/v1_status.md >/dev/null ||
    ! grep -F "verifies the ${onig_checked} rows" docs/v1_status.md >/dev/null ||
    ! grep -F "${onig_skipped} skipped rows remain" docs/v1_status.md >/dev/null; then
    printf 'stale Oniguruma conformance counts in v1 status\n' >&2
    ok=0
fi

shiki_languages=$(sed -n 's/.*ZHL_EXPECT_SHIKI_LANGUAGES ?? \([0-9][0-9]*\)).*/\1/p' benchmark/shiki_ecosystem.mjs)
shiki_scopes=$(sed -n 's/.*ZHL_EXPECT_SHIKI_SCOPES ?? \([0-9][0-9]*\)).*/\1/p' benchmark/shiki_ecosystem.mjs)
shiki_roots=$(sed -n 's/.*ZHL_EXPECT_SHIKI_INCLUDE_ROOTS ?? \([0-9][0-9]*\)).*/\1/p' benchmark/shiki_ecosystem.mjs)
shiki_include_scopes=$(sed -n 's/.*ZHL_EXPECT_SHIKI_INCLUDE_SCOPES ?? \([0-9][0-9]*\)).*/\1/p' benchmark/shiki_ecosystem.mjs)
shiki_pairs=$(sed -n 's/.*ZHL_EXPECT_SHIKI_INCLUDE_PAIRS ?? \([0-9][0-9]*\)).*/\1/p' benchmark/shiki_ecosystem.mjs)
if ! grep -F "all ${shiki_languages} Shiki language routes" docs/v1_status.md >/dev/null ||
    ! grep -F "${shiki_scopes}-scope TextMate corpus" docs/v1_status.md >/dev/null ||
    ! grep -F "the ${shiki_languages} route, ${shiki_scopes} scope, ${shiki_roots} dependency-root, ${shiki_include_scopes} dependency-target-scope," docs/v1_status.md >/dev/null ||
    ! grep -F "and ${shiki_pairs} direct cross-scope include-pair counts" docs/v1_status.md >/dev/null; then
    printf 'stale Shiki ecosystem counts in v1 status\n' >&2
    ok=0
fi

[ "$ok" -eq 1 ]
