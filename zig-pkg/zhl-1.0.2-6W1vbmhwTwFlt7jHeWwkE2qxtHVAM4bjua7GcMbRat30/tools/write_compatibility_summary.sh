#!/usr/bin/env sh
set -eu

out_dir=${1:-zig-out/compatibility}
mkdir -p "$out_dir"

summary_json="$out_dir/summary.json"
summary_md="$out_dir/summary.md"
corpus_root=${ZHL_CORPUS_CACHE:-.zig-cache/zhl-corpus}

ZHL_CORPUS_CACHE=$corpus_root sh tools/fetch_corpus_cache.sh >/dev/null

count_files() {
    dir=$1
    name=$2
    find "$dir" -maxdepth 1 -type f -name "$name" | wc -l | tr -d ' '
}

corpus_path() {
    printf '%s/%s' "$corpus_root" "$1"
}

textmate_json=$(count_files "$(corpus_path grammars/textmate)" '*.tmLanguage.json')
textmate_plist=$(find "$(corpus_path tests/fixtures/textmate_plist_external)" -maxdepth 1 -type f -name '*.tmLanguage' ! -name 'host.tmLanguage' ! -name 'embedded.tmLanguage' | wc -l | tr -d ' ')
sublime_packaged=$(count_files "$(corpus_path grammars/sublime-packs)" '*.zhlb')
sublime_external=$(find "$(corpus_path tests/fixtures/sublime_external)" -maxdepth 1 -type f -name '*.sublime-syntax.part00' | wc -l | tr -d ' ')
onig_skipped=$(sed -n 's/.*ZHL_EXPECT_ONIG_SKIPPED ?? \([0-9][0-9]*\)).*/\1/p' benchmark/check_oniguruma_cases.mjs)

jsonl_count() {
    file=$1
    [ -s "$file" ] || { printf '0\n'; return; }
    wc -l <"$file" | tr -d ' '
}

jsonl_sum() {
    file=$1
    field=$2
    [ -s "$file" ] || { printf '0\n'; return; }
    node -e '
const fs = require("fs")
const [file, field] = process.argv.slice(1)
let total = 0
for (const line of fs.readFileSync(file, "utf8").trim().split(/\n/).filter(Boolean)) {
  total += Number(JSON.parse(line)[field] ?? 0)
}
console.log(total)
' "$file" "$field"
}

jsonl_count_expr() {
    file=$1
    expr=$2
    [ -s "$file" ] || { printf '0\n'; return; }
    node -e '
const fs = require("fs")
const [file, expr] = process.argv.slice(1)
let total = 0
for (const line of fs.readFileSync(file, "utf8").trim().split(/\n/).filter(Boolean)) {
  const row = JSON.parse(line)
  if (Function("row", `return (${expr})`)(row)) total += 1
}
console.log(total)
' "$file" "$expr"
}

oracle_spans="$out_dir/oracle_spans.jsonl"
corpus_regex="$out_dir/corpus-regex-patterns.jsonl"
oracle_span_supported=$(jsonl_count_expr "$oracle_spans" 'row.state === "supported"')
oracle_span_unsupported=$(jsonl_count_expr "$oracle_spans" 'row.state !== "supported"')
accepted_divergence=$(jsonl_sum "$oracle_spans" accepted_divergences)
corpus_regex_records=$(jsonl_count "$corpus_regex")
corpus_regex_unsupported=$(jsonl_count_expr "$corpus_regex" '!row.ok')
corpus_regex_skipped=$(jsonl_sum "$corpus_regex" skipped)
silent_skips=$corpus_regex_skipped
unsupported=$((oracle_span_unsupported + corpus_regex_unsupported))

cat >"$summary_json" <<EOF
{
  "schema": "zhl.compatibility-summary.v1",
  "corpus_manifest": "corpus/manifest.json",
  "reason_codes": "docs/compatibility_reason_codes.md",
  "counts": {
    "textmate_json_supported": $textmate_json,
    "textmate_plist_supported": $textmate_plist,
    "sublime_packaged_supported": $sublime_packaged,
    "sublime_external_supported": $sublime_external,
    "oracle_span_supported": $oracle_span_supported,
    "corpus_regex_supported": $corpus_regex_records,
    "accepted_divergence": $accepted_divergence,
    "oracle_skipped": $onig_skipped,
    "unsupported": $unsupported,
    "silent_skips": $silent_skips
  },
  "reason_code_counts": {
    "ZHL-COMPAT-TEXTMATE-001": $((textmate_json + textmate_plist)),
    "ZHL-COMPAT-SUBLIME-001": $((sublime_packaged + sublime_external)),
    "ZHL-COMPAT-ONIG-002": 3,
    "ZHL-COMPAT-ONIG-003": 1,
    "ZHL-COMPAT-ONIG-004": 6,
    "ZHL-COMPAT-ONIG-005": 1
  }
}
EOF

cat >"$summary_md" <<EOF
# Compatibility Summary

| category | count |
| --- | ---: |
| TextMate JSON supported | $textmate_json |
| TextMate plist supported | $textmate_plist |
| Sublime packaged supported | $sublime_packaged |
| Sublime external supported | $sublime_external |
| oracle span supported | $oracle_span_supported |
| corpus regex supported | $corpus_regex_records |
| accepted divergence | $accepted_divergence |
| oracle skipped | $onig_skipped |
| unsupported | $unsupported |
| silent skips | $silent_skips |

Reason codes: docs/compatibility_reason_codes.md
EOF

if [ "$silent_skips" -ne 0 ]; then
    printf 'compatibility summary has silent skips: %s\n' "$silent_skips" >&2
    exit 1
fi
