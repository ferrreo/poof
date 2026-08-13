# zhl Migration Guide

This guide covers moving existing highlighters or grammars to zhl v1.

## From TextMate JSON

Use offline conversion:

```sh
zhlc report-textmate-json grammar.tmLanguage.json --skipped --include-dir grammars/textmate
zhlc convert-textmate-json grammar.tmLanguage.json out.zhl --include-dir grammars/textmate
zhlc check-native out.zhl
zhlc compile-native out.zhl out.zig
zhlc pack-native out.zhl out.zhlb
```

`missing=0`, `external_missing=0`, and `skipped=0` are the release-quality
bar. Fix converter support or grammar input before shipping generated output;
do not load TextMate JSON at runtime.

## From TextMate plist

Use the plist commands with the same offline boundary:

```sh
zhlc report-textmate-plist grammar.tmLanguage --skipped --include-dir grammars/textmate
zhlc convert-textmate-plist grammar.tmLanguage out.zhl --include-dir grammars/textmate
zhlc check-native out.zhl
```

External includes can also be passed with repeated `--include-grammar FILE`.
Committed third-party grammars need matching license files.

## From Sublime Syntax

Convert Sublime source syntax files before runtime:

```sh
zhlc report-sublime syntax.sublime-syntax --skipped
zhlc convert-sublime syntax.sublime-syntax out.zhl
zhlc check-native out.zhl
zhlc compile-native out.zhl out.zig
```

`extends`, variables, `push`/`set`/`pop`, captures, and common dynamic
backreference exits are handled by the offline converter. Any executable skip
is a converter gap to fix before claiming support for that grammar.

## From Shiki Or vscode-textmate

Treat Shiki or `vscode-textmate` grammars as TextMate sources. Convert them
offline, ship generated `.zig` or `.zhlb` artifacts, and run differential checks
against Shiki for the language routes you expose:

```sh
zig build check-shiki-ecosystem -Doptimize=ReleaseFast
zig build check-diff-native -Doptimize=ReleaseFast
zig build check-visual -Doptimize=ReleaseFast
```

Runtime code should call `zhl.Engine` with generated grammars. It should not
instantiate an Oniguruma scanner or parse JSON grammar files per highlight.

## From syntect

Convert Sublime syntax sources offline, then compare output and allocation
behavior with the benchmark harness:

```sh
zig build check-bench-native -Doptimize=ReleaseFast
zig build check-wasm-bench -Doptimize=ReleaseFast
benchmark/run_compare.sh
```

The zhl hot path uses caller-owned `State`, `Scratch`, and sinks. Move
per-document state into `LineCache` or caller storage instead of allocating
during `highlightLine`.

## Optional Tree-sitter Overlay

Keep parser libraries outside the core runtime. Run a Tree-sitter parser in
caller or benchmark code, map query captures to `zhl.tree_sitter.Capture`, and
apply them over native zhl tokens:

```sh
zig build tree-sitter-example
zig build check-tree-sitter -Doptimize=ReleaseFast
```

The release proof route uses JavaScript via Node `tree-sitter` packages and
does not add parser or C interop dependencies to `src/`.

## Native zhl Grammars

For hand-tuned grammars, start with `docs/native_dsl.md` and validate every
change:

```sh
zhlc check-native grammar.zhl
zhlc compile-native grammar.zhl grammar.zig
zhlc pack-native grammar.zhl grammar.zhlb
```

Prefer native rules for literals, comments, strings, delimiters, and simple
regexes. Use `regex_vm` rules only when Oniguruma semantics are required.

## Supported v1 Corpus Boundary

Current v1 compatibility evidence is corpus-bounded. The checked release corpus
is 26 native grammars: Bash, C, C++, C#, CSS, Go, HTML, Java, JavaScript, JSX,
JSON, Kotlin, Log, Markdown, PHP, Python, Ruby, Rust, SQL, Swift, TOML, TSX,
TypeScript, XML, YAML, and Zig 0.16; 271 checked-in TextMate JSON grammars with
tracked `.zhlb` packs; local TextMate plist fixtures plus eight external plist
grammars; 113 packaged Sublime syntaxes with tracked `.zhlb` packs; and
external TextMate/Sublime fixture sets documented in `docs/v1_status.md`.

For grammars outside that boundary, run the relevant `report-*`, `convert-*`,
`check-native`, generated-Zig compile, and visual/differential checks before
claiming support. Unsupported executable rules are converter or regex gaps to
fix, not runtime fallbacks.

## Runtime Integration

The stable runtime path is:

1. Import `zhl` and a generated grammar.
2. Instantiate `zhl.Engine(grammar, options)`.
3. Keep `State` per line or document.
4. Reuse one caller-owned `Scratch` per highlighting worker.
5. Emit to a sink or renderer.

TextMate, plist, Sublime, and theme parsing are compiler/tooling concerns.
`zig build check-runtime-boundary` enforces that the runtime stays separate
from offline importers and converters.
