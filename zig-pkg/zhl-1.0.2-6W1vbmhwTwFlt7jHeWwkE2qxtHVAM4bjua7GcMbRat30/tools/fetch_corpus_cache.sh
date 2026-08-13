#!/usr/bin/env sh
set -eu

cache=${ZHL_CORPUS_CACHE:-.zig-cache/zhl-corpus}

case "$cache" in
    "$PWD"|"$PWD"/*)
        case "$cache" in
            "$PWD/.zig-cache"|"$PWD/.zig-cache"/*) ;;
            *)
                printf 'ZHL_CORPUS_CACHE must not point at a tracked repo path: %s\n' "$cache" >&2
                exit 1
                ;;
        esac
        ;;
esac

if [ "${ZHL_OFFLINE:-}" = 1 ]; then
    if [ ! -s "$cache/manifest.json" ] || [ ! -s "$cache/corpus_summary.json" ]; then
        printf 'ZHL_OFFLINE=1 and corpus cache is missing required artifacts: %s\n' "$cache" >&2
        exit 1
    fi
    printf 'corpus cache ready: %s\n' "$cache"
    exit 0
fi

tmp="$cache.tmp.$$"
rm -rf "$tmp"
mkdir -p "$tmp/grammars" "$tmp/tests/fixtures"
cp corpus/manifest.json "$tmp/manifest.json"
cp docs/corpus_summary.json "$tmp/corpus_summary.json"

generate_textmate_sources() {
    out_dir=$1
    mkdir -p "$out_dir"
    cp grammars/textmate/LICENSE.md "$out_dir/LICENSE.md"
    TARGET="$out_dir" node --input-type=module <<'NODE'
import { readdirSync, readFileSync, writeFileSync } from 'node:fs'

const dist = 'benchmark/node_modules/@shikijs/langs/dist'
const out = process.env.TARGET
const byKey = new Map()
for (const mjs of readdirSync(dist).filter((file) => file.endsWith('.mjs') && file !== 'index.mjs')) {
  const mod = await import(`./${dist}/${mjs}`)
  for (const lang of mod.default) byKey.set(`${lang.name}\0${lang.scopeName}`, lang)
}

for (const file of readdirSync('grammars/textmate').filter((file) => file.endsWith('.tmLanguage.json')).sort()) {
  const current = JSON.parse(readFileSync(`grammars/textmate/${file}`, 'utf8'))
  const lang = byKey.get(`${current.name}\0${current.scopeName}`)
  if (lang) writeFileSync(`${out}/${file}`, `${JSON.stringify(lang)}\n`)
}
NODE
    # ponytail: repo fallback only for first-party/extra-source grammars not in @shikijs/langs; remove when each has an upstream fetch.
    for file in grammars/textmate/*.tmLanguage.json; do
        base=${file##*/}
        [ -f "$out_dir/$base" ] || cp "$file" "$out_dir/$base"
    done
}

fetch_sublime_repo() {
    repo=$1
    git init -q "$repo"
    git -C "$repo" remote add origin https://github.com/sublimehq/Packages
    git -C "$repo" fetch -q --depth 1 origin d9b8221ee37ef8f6376f33ac53a175c08962f516
    git -C "$repo" checkout -q FETCH_HEAD
}

sublime_split_mode() {
    case "$1" in
        "CSS"|"Go"|"HTML"|"Markdown"|"YAML") printf '%s\n' bytes ;;
        "Lua"|"TypeScript"|"XML") printf '%s\n' lines500 ;;
        "ASP"|"ActionScript"|"AppleScript"|"Bash"|"Batch File"|"C#"|"C++"|"C"|"D"|"DOT"|"Erlang"|"HTML (JSP)"|"Haskell"|"Java"|"JavaScript"|"LaTeX"|"Lisp"|"Matlab"|"MySQL"|"OCaml"|"Objective-C++"|"Objective-C"|"PHP Source"|"Perl"|"Python"|"Ruby"|"Rust"|"SQL (basic)"|"TSQL"|"TeX"|"Textile"|"Zsh")
            printf '%s\n' lines700
            ;;
        *) printf '%s\n' copy ;;
    esac
}

split_sublime_source() {
    src=$1
    out_dir=$2
    base=$3
    split_prefix="$out_dir/${base}.sublime-syntax.part"
    case "$(sublime_split_mode "$base")" in
        bytes) split -d -a 2 -b 20000 "$src" "$split_prefix" ;;
        lines500) split -d -a 2 -l 500 "$src" "$split_prefix" ;;
        lines700) split -d -a 2 -l 700 "$src" "$split_prefix" ;;
        copy) cp "$src" "${split_prefix}00" ;;
    esac
}

generate_sublime_sources() {
    repo=$1
    lock=$2
    prefix=$3
    out_dir=$4
    paths=${TMPDIR:-/tmp}/zhl-sublime-paths.$$
    mkdir -p "$out_dir"
    sed 's/^[0-9a-f]*  //' "$lock" >"$paths"
    while IFS= read -r path <&3; do
        case "$path" in
            "$prefix"/*.sublime-syntax.part00)
                file=${path#"$prefix"/}
                base=${file%.sublime-syntax.part00}
                matches=$(find "$repo" -type f -name "${base}.sublime-syntax")
                if [ "$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')" != 1 ]; then
                    printf 'ambiguous Sublime source for %s\n' "$base" >&2
                    exit 1
                fi
                split_sublime_source "$matches" "$out_dir" "$base"
                ;;
        esac
    done 3<"$paths"
    rm -f "$paths"
}

generate_sublime_external_sources() {
    repo=$1
    out_dir=$2
    mkdir -p "$out_dir"
    while IFS= read -r base; do
        matches=$(find "$repo" -type f -name "${base}.sublime-syntax")
        if [ "$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')" != 1 ]; then
            printf 'ambiguous external Sublime source for %s\n' "$base" >&2
            exit 1
        fi
        split_sublime_source "$matches" "$out_dir" "$base"
    done <<'EOF'
C
CSS
Diff
Diff (Basic)
Git Config
Go
HTML
HTML (Plain)
JSON
JavaProperties
JavaScript
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

split_textmate_external_source() {
    src=$1
    out_dir=$2
    base=$3
    split -d -a 2 -l 700 "$src" "$out_dir/${base}.tmLanguage.json.part"
}

download_textmate_external_sources() {
    out_dir=$1
    src_dir=$2
    rev=7207f731a477434811e61ca70e6c66ee4dc393fd
    mkdir -p "$out_dir" "$src_dir"
    find tests/fixtures/textmate_external -maxdepth 1 -type f ! -name '*.tmLanguage.json.part*' -exec cp {} "$out_dir/" \;
    while read -r base path; do
        url="https://raw.githubusercontent.com/microsoft/vscode/$rev/$path"
        src="$src_dir/${base}.tmLanguage.json"
        curl -fsSL "$url" -o "$src"
        case "$base" in
            Docker|JSONC) printf '\n' >>"$src" ;;
        esac
        split_textmate_external_source "$src" "$out_dir" "$base"
    done <<'EOF'
ASPVBNet extensions/vb/syntaxes/asp-vb-net.tmLanguage.json
Batch extensions/bat/syntaxes/batchfile.tmLanguage.json
Bibtex extensions/latex/syntaxes/Bibtex.tmLanguage.json
CSS extensions/css/syntaxes/css.tmLanguage.json
Clojure extensions/clojure/syntaxes/clojure.tmLanguage.json
Dart extensions/dart/syntaxes/dart.tmLanguage.json
Diff extensions/diff/syntaxes/diff.tmLanguage.json
Docker extensions/docker/syntaxes/docker.tmLanguage.json
Dotenv extensions/dotenv/syntaxes/dotenv.tmLanguage.json
GitCommit extensions/git-base/syntaxes/git-commit.tmLanguage.json
GitRebase extensions/git-base/syntaxes/git-rebase.tmLanguage.json
Go extensions/go/syntaxes/go.tmLanguage.json
HLSL extensions/hlsl/syntaxes/hlsl.tmLanguage.json
HTML extensions/html/syntaxes/html.tmLanguage.json
INI extensions/ini/syntaxes/ini.tmLanguage.json
Ignore extensions/git-base/syntaxes/ignore.tmLanguage.json
Java extensions/java/syntaxes/java.tmLanguage.json
JavaScript extensions/javascript/syntaxes/JavaScript.tmLanguage.json
JavaScriptReact extensions/javascript/syntaxes/JavaScriptReact.tmLanguage.json
JSON extensions/json/syntaxes/JSON.tmLanguage.json
JSONC extensions/json/syntaxes/JSONC.tmLanguage.json
JSONL extensions/json/syntaxes/JSONL.tmLanguage.json
MagicRegExp extensions/python/syntaxes/MagicRegExp.tmLanguage.json
Makefile extensions/make/syntaxes/make.tmLanguage.json
ObjectiveC extensions/objective-c/syntaxes/objective-c.tmLanguage.json
PowerShell extensions/powershell/syntaxes/powershell.tmLanguage.json
Python extensions/python/syntaxes/MagicPython.tmLanguage.json
R extensions/r/syntaxes/r.tmLanguage.json
Rust extensions/rust/syntaxes/rust.tmLanguage.json
SCSS extensions/scss/syntaxes/scss.tmLanguage.json
SQL extensions/sql/syntaxes/sql.tmLanguage.json
SassDoc extensions/scss/syntaxes/sassdoc.tmLanguage.json
ShaderLab extensions/shaderlab/syntaxes/shaderlab.tmLanguage.json
Shell extensions/shellscript/syntaxes/shell-unix-bash.tmLanguage.json
Swift extensions/swift/syntaxes/swift.tmLanguage.json
TeX extensions/latex/syntaxes/TeX.tmLanguage.json
TypeScript extensions/typescript-basics/syntaxes/TypeScript.tmLanguage.json
TypeScriptReact extensions/typescript-basics/syntaxes/TypeScriptReact.tmLanguage.json
XML extensions/xml/syntaxes/xml.tmLanguage.json
XSL extensions/xml/syntaxes/xsl.tmLanguage.json
EOF
}

find grammars -maxdepth 1 -type f \( -name '*.zhl' -o -name '*.zhlb' \) -exec cp {} "$tmp/grammars/" \;
generate_textmate_sources "$tmp/grammars/textmate"
cp -R grammars/textmate-packs "$tmp/grammars/textmate-packs"
sublime_repo="$tmp/upstream-sublime"
fetch_sublime_repo "$sublime_repo"
generate_sublime_sources "$sublime_repo" corpus/locks/sublime-source.sha256 grammars/sublime "$tmp/grammars/sublime"
cp grammars/sublime/LICENSE grammars/sublime/README.md "$tmp/grammars/sublime/"
cp -R grammars/sublime-packs "$tmp/grammars/sublime-packs"
download_textmate_external_sources "$tmp/tests/fixtures/textmate_external" "$tmp/textmate-external-source"
cp -R tests/fixtures/textmate_plist_external "$tmp/tests/fixtures/textmate_plist_external"
generate_sublime_external_sources "$sublime_repo" "$tmp/tests/fixtures/sublime_external"
cp tests/fixtures/sublime_external/LICENSE tests/fixtures/sublime_external/README.md "$tmp/tests/fixtures/sublime_external/"
rm -rf "$sublime_repo"

rm -rf "$cache"
mv "$tmp" "$cache"

printf 'corpus cache ready: %s\n' "$cache"
