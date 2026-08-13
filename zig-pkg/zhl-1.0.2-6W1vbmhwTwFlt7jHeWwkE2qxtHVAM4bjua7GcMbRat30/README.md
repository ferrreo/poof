# zhl

Fully native syntax highlighting written in Zig 0.16.

```bash
zig build check-v1 -Doptimize=ReleaseFast
zig build test
zig build check-lines
tools/check_file_lines.sh --report
zig build check-corpus-counts
zig build check-integrations
zig build check-diff-native -Doptimize=ReleaseFast
zig build check-shiki-ecosystem -Doptimize=ReleaseFast
zig build check-visual -Doptimize=ReleaseFast
zig build check-bench-native -Doptimize=ReleaseFast
zig build check-wasm-bench -Doptimize=ReleaseFast
zig build check-oniguruma-cases
zig build bench -Doptimize=ReleaseFast
zig build wasm
zig-out/bin/zhlc check-native grammars/zig_0_16.zhl
zig-out/bin/zhlc dump tests/fixtures/languages/rust-textmate.rs --grammar rust
zig-out/bin/zhlc render-html tests/golden/zig_basic.input.zig --grammar zig
zig-out/bin/zhlc render-ansi tests/golden/zig_basic.input.zig --grammar zig
zig-out/bin/zhlc dump tests/golden/zig_basic.input.zig --grammar zig
zig-out/bin/zhlc convert-textmate-json tests/fixtures/textmate_string.json /tmp/textmate_string.zhl
zig-out/bin/zhlc convert-textmate-json tests/fixtures/textmate_external_host.json /tmp/textmate_external.zhl --include-grammar tests/fixtures/textmate_external_embedded.json
zig-out/bin/zhlc convert-sublime tests/fixtures/sublime_basic.sublime-syntax /tmp/sublime_basic.zhl
zig-out/bin/zhlc pack-native grammars/zig_0_16.zhl grammars/zig_0_16.zhlb
zig-out/bin/zhlc compile-native grammars/zig_0_16.zhl src/grammars/zig_0_16_generated.zig
zig-out/bin/zhlc report-textmate-json tests/fixtures/textmate_string.json --missing
zig-out/bin/zhlc report-textmate-json tests/fixtures/textmate_injections.json
zig-out/bin/zhlc report-textmate-plist tests/fixtures/textmate_injections.tmLanguage
zig-out/bin/zhlc check-theme-json tests/fixtures/theme_basic.json
zig-out/bin/zhlc check-theme-plist tests/fixtures/theme_basic.tmTheme
zig-out/bin/zhlc compile-theme-json tests/fixtures/theme_basic.json /tmp/theme_json.zig
zig-out/bin/zhlc compile-theme-plist tests/fixtures/theme_basic.tmTheme /tmp/theme_plist.zig
zig build tree-sitter-example
zig build editor-example
npm --prefix benchmark run tree-sitter
npm --prefix benchmark run diff:native
npm --prefix benchmark run visual
npm --prefix benchmark run check:shiki-ecosystem
```

The implementation spec is tracked at
`docs/zig_0_16_syntax_highlighting_engine_spec.md`.
Current v1 evidence and remaining gaps are tracked at `docs/v1_status.md`.
The native DSL is documented at `docs/native_dsl.md`; the binary grammar pack
format is documented at `docs/zhlb.md`. Native `.zhl` grammars ship for Bash,
C, C++, C#, CSS, Go, HTML, Java, JavaScript, JSX, JSON, Kotlin, Markdown, PHP,
Python, Ruby, Rust, SQL, Swift, TOML, TSX, TypeScript, XML, YAML, and Zig 0.16. The
matching `.zhlb` binary packs are tracked beside them and checked in CI. The
generated Zig grammar modules under `src/grammars` are also checked against
their `.zhl` sources in CI; `zig_0_16.zig` is the hand-tuned Zig grammar and
`zig_0_16_generated.zig` is the generated reference module.
TextMate and Sublime grammars are supported as offline converter inputs:
`convert-textmate-json`, `convert-textmate-plist`, and `convert-sublime` emit
native `.zhl` grammar files. Runtime highlighting uses registered native zhl
grammars, not TextMate JSON, plist, or Sublime files. TextMate reference
grammars in `grammars/textmate` include their source license. Generated
TextMate `.zhlb` packs are tracked in `grammars/textmate-packs`; regenerate
them with `tools/update_textmate_packs.sh`.

Benchmarks:

```bash
npm --prefix benchmark install
benchmark/run_compare.sh
```

`benchmark/run_compare.sh` compares native `zhl`, Shiki, `vscode-textmate`,
and Rust `syntect` with both `default-onig` and `default-fancy` regex backends
in release builds
over Zig 0.16, adversarial Zig, real `zhl` Zig source files, TypeScript, Rust,
Python, minified JSON, minified JavaScript, and TextMate JSON corpora. WASM
`zhl` is benchmarked over Zig 0.16 plus the first-pass P0 native fixture
corpus. `zig build check-tree-sitter` runs the benchmark/dev JavaScript
Tree-sitter overlay route.
Syntect rows are skipped, not timed, when its syntax set lacks a language. The
native `.zhl` benchmark gate checks every zhl corpus row with fast, medium, and
slow throughput floors and requires zero setup, hot, and total allocations.
`zig build check-bench-native -Doptimize=ReleaseFast` runs that native gate
against the built `zhl-bench` artifact.
`zig build check-wasm-bench -Doptimize=ReleaseFast` runs the WASM rows against
the built `zhl_wasm.wasm` artifact.
`zig build check-oniguruma-cases` validates regex VM parity rows against
Shiki's Oniguruma backend.
Fast rows default to `ZHL_MIN_NATIVE_FAST_MIB_S=20`, medium rows to
`ZHL_MIN_NATIVE_MEDIUM_MIB_S=8`, and slow rows to
`ZHL_MIN_NATIVE_SLOW_MIB_S=5`; `ZHL_MIN_NATIVE_MIB_S` remains a fast-row alias.
Highlighting uses one execution policy: grammars compile once, with generic
optimized matchers used automatically when they preserve the same result.
`npm --prefix benchmark run visual` emits `benchmark/visual/index.html` and
checks important token spans across the native `.zhl` visual route set,
including the P0 first-pass routes, against Shiki and syntect colors.
`npm --prefix benchmark run diff:native` checks those native zhl spans against
Shiki-colored spans in CI. TextMate/Sublime conversion is covered by integration
gates that convert, validate, generate native Zig, and compile the converted
grammars.

The package also exposes TextMate capture plans, bounded dynamic end matching,
VS Code theme JSON and `.tmTheme` import, and a dependency-free Tree-sitter
capture overlay for optional parser adapters. `zig build tree-sitter-example`
runs a parser-adapter overlay example; `zig build check-tree-sitter` runs a
real JavaScript parser-backed proof route. See `docs/tree_sitter.md`.
`zig build editor-example` runs a minimal editor-token adapter example using
the language metadata registry and `TokenBuffer`.

Latest local Zig-corpus rows:

| engine | backend | throughput | ns/line | setup allocations | hot allocations | total allocation evidence |
|---|---:|---:|---:|---:|---:|---:|
| `zhl` native `.zhl` | Zig matcher compiler | 139.81 MiB/s | 273.82 | 0 / 0 B | 0 / 0 B | 0 / 0 B |
| `zhl` WASM `.zhl` | WebAssembly | 90.14 MiB/s | 424.73 | 0 / 0 B | 0 / 0 B | 0 / 0 B; JS heap +10,720 B; ABI 16 B |
| Shiki | TextMate | 1.90 MiB/s | 20128.19 | heap +4,654,696 B | heap +197,280 B | counts unavailable in Node; total heap +5,503,000 B |
| vscode-textmate | Oniguruma | 2.07 MiB/s | 18532.10 | heap +4,570,552 B | heap +234,216 B | counts unavailable in Node; total heap +5,208,480 B |
| syntect | onig release | 9.91 MiB/s | 3862.53 | 178,240 / 57,357,565 B | 342,171 / 184,998,384 B | 520,411 / 242,355,949 B |
| syntect | fancy-regex release | 5.07 MiB/s | 7557.46 | 194,690 / 73,292,577 B | 873,126 / 152,428,176 B | 1,067,816 / 225,720,753 B |
