## 19. `zhlc` Compiler Pipeline

```text
1. load
   JSON / plist / YAML / native DSL / theme files

2. normalize
   resolve includes
   expand repositories
   resolve injections
   resolve embedded grammars
   canonicalize scopes

3. analyze regex
   parse Oniguruma/TextMate syntax
   choose internal matcher representations
   identify simpler equivalent rules
   compile regex VM programs where needed

4. lower
   convert begin/end/while to context stack actions
   convert match rules to emit actions
   build capture plans
   compute dynamic capture storage needs

5. optimize
   build byte masks
   build rule buckets
   build literal tries
   build keyword sets
   build operator tries
   build DFA tables
   intern scope stacks
   pre-resolve theme metadata
   pre-merge injections

6. emit
   generated Zig module
   optional .zhlb binary
   debug report
   compatibility report
   benchmark metadata
```

CLI examples:

```bash
zhlc compile textmate syntaxes/rust.tmGrammar.json \
  --scope source.rust \
  --theme themes/OneDark.json \
  --emit-zig src/generated/rust.zig \
  --report target/rust.zhl.report.json

zhlc compile native grammars/zig_0_16.zhl \
  --emit-zig src/generated/zig_0_16.zig

zhlc report-textmate-json syntaxes/python.tmGrammar.json --missing
```

Support report example:

```json
{
  "grammar": "source.example",
  "patterns": 1842,
  "supported": 1842,
  "missing": []
}
```

Reports are diagnostics. Runtime behavior stays one correct TextMate-compatible path.

---

## 20. Error Handling and Limits

Expose explicit limits:

```zig
pub const Limits = struct {
    max_stack_depth: u16 = 64,
    max_line_bytes: u32 = 1 << 20,
    max_tokens_per_line: u32 = 16_384,
    max_dynamic_capture_bytes: u16 = 256,
    max_regex_vm_stack: u16 = 1024,
    max_regex_capture_slots: u16 = 128,
    max_regex_steps_per_line: u32 = 1 << 20,
    max_dfa_steps_per_line: u32 = 1 << 20,
};
```

Errors:

```zig
pub const HighlightError = error{
    StackOverflow,
    DynamicCaptureOverflow,
    RegexVmStackOverflow,
    RegexCaptureOverflow,
    RegexStepLimitExceeded,
    TokenOverflow,
    LineTooLong,
    MalformedGrammar,
};
```

## 21. Build Integration

Generated grammars should be checked in for consumers who only want the runtime. Grammar authors can integrate `zhlc` as a build step.

Sketch:

```zig
const zhl_dep = b.dependency("zhl", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zhl", zhl_dep.module("zhl"));
exe.root_module.addImport("zhl_grammars", zhl_dep.module("zhl_grammars"));
```

Optional adapters should be separate build options:

```text
-Dzhl-tree-sitter=true
-Dzhl-wasm=true
-Dzhl-target-specialized-simd=true
```

The core regex path is native Zig; C/Onig interop is not a runtime mode. The
core library should be slice-based and I/O-free. File loading belongs in
`zhlc`, examples, or integration packages.

---

## 22. Testing Strategy

### 22.1 Unit Tests

Test primitive components:

- `indexOfAnyByte`.
- `findNextInteresting`.
- ASCII identifier scanner.
- Byte-safe scanning on arbitrary input.
- Keyword trie.
- Operator trie.
- String scanner.
- Number scanner.
- Scope interning.
- Scope stack interning.
- Theme selector resolution.
- Regex parser.
- DFA compiler.
- Regex VM.
- State push/pop.
- Dynamic capture storage.

### 22.2 Golden Tests

Use snapshot files:

```text
input.zig
expected.tokens.json
expected.scopes.txt
expected.ansi.snap
expected.html.snap
```

Golden suites should include:

- Zig stdlib files.
- TextMate grammar fixtures.
- Sublime syntax fixtures.
- Embedded language cases.
- Pathological regex cases.
- Very long lines.
- Invalid UTF-8 where applicable.

### 22.3 Differential TextMate Tests

For TextMate import, compare against reference behavior.

The harness should compare:

- Token boundaries.
- Scope stacks.
- Begin/end behavior.
- While behavior.
- Injections.
- Dynamic captures.
- Embedded grammars.
- Backreference behavior.
- `\G` behavior.
- `applyEndPatternLast` behavior.

Known reference disagreements should be captured in diagnostics, not hidden.

### 22.4 Fuzzing

Fuzz:

- Random bytes.
- Random valid UTF-8.
- Malformed grammar tables.
- Deeply nested begin/end states.
- Huge lines.
- Unterminated strings.
- Dynamic heredocs.
- Backtracking-heavy regexes.
- Random edit sequences.

Properties:

- No panics in safe builds.
- No heap allocation in hot path.
- Tokens are ordered.
- Tokens do not overlap illegally.
- Token end is never greater than line length.
- Zero-length matches cannot loop forever.
- State equality is stable.
- Incremental rehighlight from an edit equals full rehighlight from line 0.

---

## 23. Performance Targets

Performance targets should become CI gates as the project stabilizes.

Hot path:

- 0 heap allocations per line.
- O(line bytes + matches) for rules using simpler equivalent matchers.
- No theme selector matching.
- No scope string matching.
- No grammar parsing.
- No regex source parsing.
- Regex VM only for rules that cannot use a simpler equivalent matcher.

Memory:

- Compact tokens should be 8 bytes/token.
- Typical line state should stay under 256 bytes.
- Grammar tables should be read-only and shareable.
- Document caches should be caller-owned and reusable.

Latency:

- Small edits should usually rehighlight only the changed line or nearby lines.
- Large multiline constructs should converge as soon as state equality is restored.
- Long-line bailout must be configurable.
- Regex VM step limits must prevent pathological stalls.

Benchmark corpus:

```text
bench_zig_stdlib
bench_typescript_large
bench_rust_crate
bench_python_stdlib
bench_html_embedded_js_css
bench_markdown_code_fences
bench_minified_json
bench_minified_js_long_lines
bench_textmate_worst_case
bench_regex_vm_cases
```

Comparison targets:

- `vscode-textmate` plus Oniguruma.
- `syntect`.
- Tree-sitter highlighting where available.
- Hand-written Zig tokenizer baseline.
- `zhl` native/TextMate execution versus external highlighters.

---

## 24. v0.1 Acceptance Checklist

v0.1 is acceptable only when all of these are true:

- [ ] `zhl` can highlight Zig 0.16 from a native grammar.
- [ ] `zhlc` can compile native `.zhl` grammars.
- [ ] The native grammar DSL is documented.
- [ ] `highlightLine` performs zero heap allocations.
- [ ] TextMate JSON grammars compile.
- [ ] TextMate plist grammars compile.
- [ ] TextMate `match`, `begin`, `end`, `while`, captures, includes, repositories, injections, and embedded grammars are supported.
- [ ] Oniguruma-compatible regex VM is available for full TextMate support.
- [ ] Compatibility regex matching uses precompiled programs and caller-provided scratch.
- [ ] Semantically lowerable regexes are converted to native matchers or automata.
- [ ] Sublime `.sublime-syntax` import works for representative grammars.
- [ ] Themes compile to pre-resolved style IDs.
- [ ] ANSI and HTML renderers work.
- [ ] Incremental rehighlighting works and matches full rehighlight output.
- [ ] WASM build example works.
- [ ] Optional Tree-sitter overlay example works.
- [ ] Differential TextMate harness exists.
- [ ] Fuzz tests cover runtime and grammar compiler components.
- [ ] Benchmark suite exists.
- [ ] Precompiled grammar pack exists.

---

## 25. Implementation Notes for Zig 0.16

Keep the core library slice-based and I/O-free. Zig 0.16’s standard library direction around I/O makes it cleaner to isolate file loading and command-line behavior in `zhlc` and integration packages.

Use Zig comptime for:

- Grammar specialization.
- Static table generation.
- Elimination of unused matcher variants.
- Type-sized state and scratch buffers.
- Optional feature selection.

Use Zig vectors for portable SIMD-friendly scanning. Add target-specific intrinsics only behind compile-time options and only after measurement.

Optional C-backed integrations should be isolated. The core runtime should not require C translation, C libraries, or platform-specific regex engines.

---

## 26. References

These are the main external design references behind the spec:

- Zig 0.16.0 release notes: <https://ziglang.org/download/0.16.0/release-notes.html>
- Zig 0.16 language reference: <https://ziglang.org/documentation/0.16.0/>
- VS Code Syntax Highlight Guide: <https://code.visualstudio.com/api/language-extensions/syntax-highlight-guide>
- VS Code syntax-highlighting optimization notes: <https://code.visualstudio.com/blogs/2017/02/08/syntax-highlighting-optimizations>
- TextMate Language Grammars manual: <https://macromates.com/manual/en/language_grammars>
- TextMate Regular Expressions manual: <https://macromates.com/manual/en/regular_expressions>
- Sublime Syntax documentation: <https://www.sublimetext.com/docs/syntax.html>
- Tree-sitter introduction: <https://tree-sitter.github.io/>
- Microsoft `vscode-textmate`: <https://github.com/microsoft/vscode-textmate>

---

## 27. Summary

`zhl` should be built around a simple promise:

> **Accept the grammar ecosystem users already have, but execute it like a Zig-native high-performance scanner whenever possible.**

v0.1 should therefore be the complete initial release: native Zig 0.16 highlighting, full TextMate support, documented native DSL, strict no-allocation hot path, SIMD scanning, theme compilation, Sublime import, optional Tree-sitter overlay, WASM support, and a real compatibility test suite.
