#!/usr/bin/env sh
set -eu

fail=0
corpus_root=${ZHL_CORPUS_CACHE:-.zig-cache/zhl-corpus}

ZHL_CORPUS_CACHE=$corpus_root sh tools/fetch_corpus_cache.sh >/dev/null

corpus_path() {
    printf '%s/%s' "$corpus_root" "$1"
}

textmate_dir=$(corpus_path grammars/textmate)
textmate_pack_dir=$(corpus_path grammars/textmate-packs)
sublime_dir=$(corpus_path grammars/sublime)
sublime_pack_dir=$(corpus_path grammars/sublime-packs)
external_textmate_dir=$(corpus_path tests/fixtures/textmate_external)
external_plist_dir=$(corpus_path tests/fixtures/textmate_plist_external)
external_sublime_dir=$(corpus_path tests/fixtures/sublime_external)

require_file() {
    path=$1
    message=$2
    if [ ! -s "$path" ]; then
        printf '%s: %s\n' "$path" "$message" >&2
        fail=1
    fi
}

if ls "$textmate_dir"/*.tmLanguage.json >/dev/null 2>&1; then
    require_file "$textmate_dir/LICENSE.md" "required for TextMate grammars"
fi

if ls "$textmate_pack_dir"/*.zhlb >/dev/null 2>&1; then
    require_file "$textmate_dir/LICENSE.md" "required for generated TextMate packs"
fi

if ls "$external_sublime_dir"/*.sublime-syntax.part* >/dev/null 2>&1; then
    require_file "$external_sublime_dir/LICENSE" "required for Sublime corpus chunks"
fi

if ls "$external_textmate_dir"/*.tmLanguage.json.part* >/dev/null 2>&1; then
    require_file "$external_textmate_dir/LICENSE-MICROSOFT" "required for external TextMate corpus chunks"
fi

if ls "$external_textmate_dir"/Python.tmLanguage.json.part* >/dev/null 2>&1; then
    require_file "$external_textmate_dir/LICENSE-MAGICPYTHON" "required for MagicPython-derived grammar chunks"
fi

if ls "$external_textmate_dir"/Go.tmLanguage.json.part* >/dev/null 2>&1; then
    require_file "$external_textmate_dir/LICENSE-GO-SYNTAX" "required for go-syntax-derived grammar chunks"
fi

if ls "$external_textmate_dir"/Dart.tmLanguage.json.part* >/dev/null 2>&1; then
    require_file "$external_textmate_dir/LICENSE-DART-SYNTAX-HIGHLIGHT" "required for dart-syntax-highlight-derived grammar chunks"
fi

if ls "$external_textmate_dir"/ASPVBNet.tmLanguage.json.part* >/dev/null 2>&1; then
    require_file "$external_textmate_dir/LICENSE-ASP-VB-NET-TMBUNDLE" "required for ASP VB.NET grammar chunks"
fi

if ls "$external_textmate_dir"/HLSL.tmLanguage.json.part* >/dev/null 2>&1; then
    require_file "$external_textmate_dir/LICENSE-SHADERS-TMLANGUAGE" "required for shaders-tmLanguage-derived grammar chunks"
fi

if ls "$external_textmate_dir"/ShaderLab.tmLanguage.json.part* >/dev/null 2>&1; then
    require_file "$external_textmate_dir/LICENSE-SHADERS-TMLANGUAGE" "required for shaderlab grammar chunks"
fi

if ls "$external_textmate_dir"/Shell.tmLanguage.json.part* >/dev/null 2>&1; then
    require_file "$external_textmate_dir/LICENSE-BETTER-SHELL-SYNTAX" "required for better-shell-syntax-derived grammar chunks"
fi

if ls "$external_textmate_dir"/GitRebase.tmLanguage.json.part* >/dev/null 2>&1; then
    require_file "$external_textmate_dir/LICENSE-GIT-TMBUNDLE" "required for git.tmbundle-derived grammar chunks"
fi

if ls "$external_textmate_dir"/Clojure.tmLanguage.json.part* >/dev/null 2>&1; then
    require_file "$external_textmate_dir/LICENSE-LANGUAGE-CLOJURE" "required for language-clojure-derived grammar chunks"
fi

if ls "$external_textmate_dir"/ObjectiveC.tmLanguage.json.part* >/dev/null 2>&1; then
    require_file "$external_textmate_dir/LICENSE-BETTER-OBJC-SYNTAX" "required for better-objc-syntax-derived grammar chunks"
fi

if ls "$external_textmate_dir"/MagicRegExp.tmLanguage.json.part* >/dev/null 2>&1; then
    require_file "$external_textmate_dir/LICENSE-MAGICPYTHON" "required for MagicPython-derived regex grammar chunks"
fi

if ls "$external_textmate_dir"/JavaScriptReact.tmLanguage.json.part* >/dev/null 2>&1; then
    require_file "$external_textmate_dir/LICENSE-TYPESCRIPT-TMLANGUAGE" "required for TypeScript-TmLanguage-derived JavaScriptReact chunks"
fi

if ls "$external_textmate_dir"/TypeScriptReact.tmLanguage.json.part* >/dev/null 2>&1; then
    require_file "$external_textmate_dir/LICENSE-TYPESCRIPT-TMLANGUAGE" "required for TypeScript-TmLanguage-derived TypeScriptReact chunks"
fi

if ls "$external_textmate_dir"/PowerShell.tmLanguage.json.part* >/dev/null 2>&1; then
    require_file "$external_textmate_dir/LICENSE-POWERSHELL-EDITORSYNTAX" "required for EditorSyntax-derived grammar chunks"
fi

if ls "$external_textmate_dir"/R.tmLanguage.json.part* >/dev/null 2>&1; then
    require_file "$external_textmate_dir/LICENSE-VSCODE-R-SYNTAX" "required for vscode-R-syntax-derived grammar chunks"
fi

if ls "$external_textmate_dir"/Bibtex.tmLanguage.json.part* >/dev/null 2>&1; then
    require_file "$external_textmate_dir/LICENSE-VSCODE-LATEX-BASICS" "required for vscode-latex-basics-derived BibTeX chunks"
fi

if ls "$external_textmate_dir"/TeX.tmLanguage.json.part* >/dev/null 2>&1; then
    require_file "$external_textmate_dir/LICENSE-VSCODE-LATEX-BASICS" "required for vscode-latex-basics-derived TeX chunks"
fi

if ls "$external_textmate_dir"/SQL.tmLanguage.json.part* >/dev/null 2>&1; then
    require_file "$external_textmate_dir/LICENSE-VSCODE-MSSQL" "required for vscode-mssql-derived grammar chunks"
fi

if ls "$external_textmate_dir"/XSL.tmLanguage.json.part* >/dev/null 2>&1; then
    require_file "$external_textmate_dir/LICENSE-LANGUAGE-XML" "required for language-xml-derived XSL chunks"
fi

if ls "$external_textmate_dir"/SCSS.tmLanguage.json.part* >/dev/null 2>&1; then
    require_file "$external_textmate_dir/LICENSE-LANGUAGE-SASS" "required for language-sass-derived SCSS chunks"
fi

if ls "$external_textmate_dir"/SassDoc.tmLanguage.json.part* >/dev/null 2>&1; then
    require_file "$external_textmate_dir/LICENSE-LANGUAGE-SASS" "required for language-sass-derived SassDoc chunks"
fi

if [ -f "$external_plist_dir/JavaScriptNextJSON.tmLanguage" ]; then
    require_file "$external_plist_dir/LICENSE-JAVASCRIPTNEXT" "required for JavaScriptNext plist grammar"
fi

if [ -f "$external_plist_dir/GitCommit.tmLanguage" ]; then
    require_file "$external_plist_dir/LICENSE-GIT-TMBUNDLE" "required for Git plist grammar"
fi

if [ -f "$external_plist_dir/Diff.tmLanguage" ]; then
    require_file "$external_plist_dir/LICENSE-DIFF-TMBUNDLE" "required for Diff plist grammar"
fi

if ls "$external_plist_dir/Ada.tmLanguage" \
    "$external_plist_dir/ANTLR.tmLanguage" \
    "$external_plist_dir/Apache.tmLanguage" \
    "$external_plist_dir/DOT.tmLanguage" \
    "$external_plist_dir/Ini.tmLanguage" >/dev/null 2>&1; then
    require_file "$external_plist_dir/LICENSE-TEXTMATE-BUNDLES" "required for TextMate plist bundle grammars"
fi

if ls "$sublime_dir"/*.sublime-syntax.part* >/dev/null 2>&1; then
    require_file "$sublime_dir/LICENSE" "required for Sublime grammars"
fi

if ls "$sublime_pack_dir"/*.zhlb >/dev/null 2>&1; then
    require_file "$sublime_dir/LICENSE" "required for generated Sublime packs"
fi

if [ -f benchmark/corpus/third_party/c_real_gzread.c ]; then
    require_file benchmark/corpus/licenses/ZLIB.txt "required for zlib corpus source"
fi

if [ -f benchmark/corpus/third_party/python_real_requests_adapters.py ]; then
    require_file benchmark/corpus/licenses/REQUESTS-APACHE-2.0.txt "required for requests corpus source"
fi

if [ -f benchmark/corpus/third_party/typescript_real_vscode_range.ts ]; then
    require_file benchmark/corpus/licenses/VSCODE-MIT.txt "required for VS Code corpus source"
fi

exit "$fail"
