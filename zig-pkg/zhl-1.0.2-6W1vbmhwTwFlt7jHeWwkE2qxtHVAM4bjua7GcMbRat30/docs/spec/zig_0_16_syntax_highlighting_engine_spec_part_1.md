# Zig 0.16 Syntax Highlighting Engine Specification

**Working name:** `zhl`  
**Primary implementation language:** Zig 0.16  
**Primary release target:** v0.1 full-scope release  
**Primary design rule:** TextMate compatibility is a grammar-import and compatibility requirement; the runtime should still optimize away regex execution whenever possible.

This document specifies a high-performance syntax-highlighting library written in Zig 0.16. The library should provide first-class Zig 0.16 highlighting, full TextMate grammar support, a documented native grammar DSL, strict no-allocation highlighting in the hot path, and optional integrations for other grammar ecosystems.

The important design distinction is this:

> **Regex syntax may exist in imported grammars. A backtracking regex engine must not be the default execution strategy for rules that can be lowered into faster deterministic matchers.**

For complete TextMate compatibility, v0.1 includes an Oniguruma-compatible regex VM/backend for rules that need those semantics. That path must still obey the no-allocation hot-path contract by using precompiled regex programs and caller-provided scratch storage.

---

## 1. Product Goals

`zhl` should be a library and toolchain for editors, terminals, static-site generators, documentation tools, code browsers, and language tooling.

The core goals are:

1. **Zig 0.16 native performance.** Use compile-time specialization, static grammar tables, packed token formats, SIMD-friendly byte scanning, and allocation-free line highlighting.
2. **Full TextMate support in v0.1.** Import TextMate JSON/plist grammars, support the full grammar surface, and provide Oniguruma-compatible matching semantics where necessary.
3. **Documented native grammar DSL in v0.1.** Provide a first-class DSL for hand-tuned grammars that do not need to pretend everything is regex.
4. **Strict no-allocation hot path in v0.1.** `highlightLine` and incremental rehighlighting must not allocate. All memory is static, caller-owned, or preallocated.
5. **High-quality Zig 0.16 grammar.** Ship a native, hand-tuned Zig 0.16 grammar as the flagship grammar and benchmark.
6. **Large ecosystem reach.** Support TextMate, Sublime Syntax, optional Tree-sitter overlays, theme compilation, and precompiled grammar packs.
7. **Deterministic editor behavior.** Use line-oriented tokenization with compact line states so incremental edits retokenize only the affected range.

Non-goals for the core runtime:

- Loading files.
- Parsing JSON, plist, YAML, or theme files at highlight time.
- Allocating during `highlightLine`.
- Running scope selector matching during token emission.
- Requiring C dependencies in the default native runtime.

---

## 2. Version Scope

v0.1 is intentionally a full-scope release, not a small proof of concept. Everything that was previously staged across v0.1, v0.2, v0.3, and v0.4 is folded into v0.1. Two v1.0 items are also folded into v0.1: the documented native grammar DSL and the strict no-allocation hot path.

### v0.1 Required Scope

v0.1 must include:

- `zhl` core runtime.
- Native Zig 0.16 grammar.
- Documented native grammar DSL.
- Full TextMate JSON and plist importer.
- Full TextMate runtime semantics.
- Oniguruma-compatible regex VM/backend.
- Regex analysis and lowering pipeline.
- SIMD byte-scanning primitives.
- Zero-allocation `highlightLine` hot path.
- Compact token format.
- Incremental line-state cache.
- ANSI renderer.
- HTML renderer.
- Theme compiler and pre-resolved style IDs.
- Sublime `.sublime-syntax` importer.
- Optional Tree-sitter overlay/backend.
- Precompiled grammar pack.
- WASM build target.
- Editor integration examples.
- Compatibility test harness against existing TextMate behavior.
- Golden tests, fuzz tests, and benchmark suite.

### v1.0 Remaining Scope

v1.0 should be a hardening and stability release, not the first complete implementation. Remaining v1.0 work should focus on:

- Stable public API.
- Stable generated grammar ABI.
- Stable `.zhlb` binary grammar format.
- CI benchmark gates.
- Expanded curated grammar suite.
- Long-term compatibility guarantees.
- Documentation polish and migration guides.

---

## 3. Architecture Overview

```text
                 ┌──────────────────────┐
 TextMate JSON ─▶│                      │
 TextMate plist ─▶│                      │
 Sublime YAML ──▶│  zhlc grammar compiler│──▶ generated .zig grammar module
 native .zhl ───▶│                      │──▶ optional .zhlb binary grammar
 themes JSON ───▶│                      │──▶ compiled theme metadata
                 └──────────────────────┘
                            │
                            ▼
                   ┌────────────────┐
                   │   zhl runtime  │
                   │  SIMD scanner  │
                   │  state machine │
                   │  regex VM     │
                   └────────────────┘
                            │
             ┌──────────────┼──────────────┐
             ▼              ▼              ▼
        editor tokens    ANSI/HTML      debug scopes
```

The runtime must not parse grammar files, theme files, or regex source strings. It receives compiled tables and precompiled matcher bytecode.

The grammar compiler, `zhlc`, performs heavyweight work ahead of time:

- Parses grammar source formats.
- Resolves includes, repositories, injections, and embedded grammars.
- Parses TextMate regexes.
- Lowers semantically compatible rules into native matchers.
- Compiles complex regexes into an Oniguruma-compatible bytecode representation.
- Interns scopes and scope stacks.
- Resolves theme selectors.
- Emits static Zig tables or a binary `.zhlb` grammar.

The runtime performs only:

- Line-oriented scanning.
- State transitions.
- Token emission.
- Regex VM matching for rules that cannot be represented by faster matchers.

---

## 4. Package Layout

| Package | Purpose |
|---|---|
| `zhl` | Core runtime highlighter. No file I/O, no grammar parsing, no hot-path allocation. |
| `zhlc` | Grammar compiler CLI and build tool. Converts TextMate, Sublime, native DSL, and themes into generated tables. |
| `zhl-grammars` | Curated precompiled grammar pack, including `zig_0_16`. |
| `zhl-theme` | Theme parser/compiler and style resolver. May live inside `zhlc` initially. |
| `zhl-textmate` | Full TextMate importer, TextMate semantic model, and compatibility tests. |
| `zhl-re` | Regex parser, optimizer, DFA compiler, and Oniguruma-compatible regex VM. |
| `zhl-tree` | Optional Tree-sitter overlay/backend for languages where structural highlighting is useful. |
| `zhl-wasm` | WASM-facing runtime wrapper and packed ABI examples. |
| `zhl-editors` | Example adapters for editor integrations. |

The default dependency graph should keep `zhl` small. C-backed or platform-specific adapters must be optional.

---

## 5. Core Runtime API

The runtime API should be generic over grammar and sink so Zig can specialize the engine at compile time.

```zig
const std = @import("std");
const zhl = @import("zhl");
const zig_grammar = @import("zhl_grammars/zig_0_16.zig");

const Highlighter = zhl.Engine(zig_grammar.grammar, .{
    .max_stack_depth = 64,
    .offset_type = u32,
    .simd = .auto,
    .emit_scopes = false,
    .emit_style_ids = true,
});

pub fn highlightExample(source: []const u8) !void {
    var h = Highlighter.init(.{});
    var state = Highlighter.State.initial();
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.DebugSink.init();

    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        const result = try h.highlightLine(line, state, &scratch, &sink);
        state = result.end_state;
    }
}
```

Public API sketch:

```zig
pub fn Engine(
    comptime grammar: Grammar,
    comptime options: EngineOptions,
) type;

pub const EngineOptions = struct {
    max_stack_depth: u16 = 64,
    max_dynamic_capture_bytes: u16 = 256,
    max_regex_vm_stack: u16 = 1024,
    offset_type: type = u32,
    emit_scopes: bool = false,
    emit_style_ids: bool = true,
};

pub const Token = struct {
    start: u32,
    end: u32,
    style_id: StyleId,
    scope_stack_id: ScopeStackId = .none,
    language_id: u16 = 0,
};

pub const LineResult = struct {
    end_state: State,
    token_count: usize,
};
```

The token sink should use comptime duck typing in the hot path:

```zig
pub fn emit(self: *Self, token: zhl.Token) !void;
```

A dynamic sink adapter can exist for editor integrations that need ABI stability, but the default runtime should avoid virtual dispatch.

---

## 6. Strict No-Allocation Hot Path

This is a v0.1 requirement.

The following operations must allocate zero heap memory:

- `Engine.init` after static grammar tables are available, unless explicitly configured to allocate document caches.
- `highlightLine`.
- Regex compatibility matching.
- Token emission into a caller-provided sink.
- Incremental rehighlighting over already allocated document buffers.
- Theme/style lookup during highlighting.

The runtime may use:

- Compile-time constants.
- Static grammar tables.
- Stack memory with bounded sizes.
- Caller-provided scratch memory.
- Caller-provided token buffers.
- Caller-provided document caches.

The runtime must not use:

- `std.heap` allocators in `highlightLine`.
- Dynamic string interning during highlighting.
- JSON/YAML/plist parsing during highlighting.
- Regex source parsing during highlighting.
- Theme selector matching during highlighting.

The API should make allocation impossible or obvious:

```zig
pub fn highlightLine(
    self: *Engine,
    line: []const u8,
    state: State,
    scratch: *Scratch,
    sink: anytype,
) HighlightError!LineResult;
```

`Scratch` is sized at compile time from engine options and grammar requirements:

```zig
pub const Scratch = struct {
    dynamic_captures: [max_dynamic_capture_bytes]u8,
    regex_vm_stack: [max_regex_vm_stack]RegexVmFrame,
    capture_slots: [max_capture_slots]CaptureSlot,
    temporary_scope_stack: [max_stack_depth]ScopeStackId,
};
```

Any code path that needs more memory must return an explicit error, such as `DynamicCaptureOverflow`, `RegexVmStackOverflow`, or `TokenOverflow`.

---

## 7. Runtime Data Model

Use byte offsets internally. They are fast, compact, and map well to Zig source. UTF-16 or code-point offsets should be adapter concerns.

```zig
pub const Grammar = struct {
    name: []const u8,
    scope_root: ScopeId,

    contexts: []const Context,
    rules: []const Rule,

    matchers: MatcherTable,
    scopes: ScopeTable,
    theme: ?CompiledTheme,

    context_start_masks: []const ByteMask256,
    context_rule_buckets: []const RuleBucket,

    textmate: ?TextMateMetadata,
    regex_programs: []const RegexProgram,
};

pub const Context = packed struct {
    first_rule: u32,
    rule_count: u16,
    default_scope: ScopeStackId,
    flags: ContextFlags,
};

pub const Rule = packed struct {
    matcher_id: MatcherId,
    action: ActionId,
    priority: u16,
    scope: ScopeId,
    capture_plan: CapturePlanId,
    textmate_rule_id: u32,
};

pub const Frame = packed struct {
    context_id: ContextId,
    scope_stack_id: ScopeStackId,
    end_matcher_id: MatcherId,
    while_matcher_id: MatcherId,
    dynamic_capture_offset: u16,
    dynamic_capture_len: u16,
};

pub fn State(comptime max_depth: u16, comptime max_capture_bytes: u16) type {
    return struct {
        depth: u16,
        frames: [max_depth]Frame,
        dynamic_captures: [max_capture_bytes]u8,
        fingerprint: u64,
    };
}
```

State must be cheap to compare:

```zig
pub fn eql(a: State, b: State) bool {
    return a.fingerprint == b.fingerprint and fullStateEql(a, b);
}
```

The fingerprint is an optimization, not a substitute for full equality when exact correctness matters.

---

## 8. Grammar Sources

### 8.1 Native `zhl` Grammar DSL

The native DSL is required in v0.1 and must be documented well enough for grammar authors.

The DSL should express common highlighting constructs directly instead of encoding everything as regex.

Example:

```zhl
grammar "source.zig" {
    name "Zig 0.16";
    file_extensions ["zig", "zon"];

    scope root = "source.zig";

    context main {
        line_comment "///" scope "comment.line.documentation.zig";
        line_comment "//!" scope "comment.line.documentation.container.zig";
        line_comment "//"  scope "comment.line.double-slash.zig";

        string "\"" escape "\\" scope "string.quoted.double.zig";
        char "'" escape "\\" scope "constant.character.zig";

        multiline_prefix "\\\\" scope "string.quoted.multiline.zig";

        keywords zig_keywords scope "keyword.control.zig";
        builtin_prefix "@" scope "support.function.builtin.zig";
        number zig_number scope "constant.numeric.zig";

        operators zig_operators scope "keyword.operator.zig";
    }
}
```

The native DSL should support:

- Contexts.
- Includes.
- Push, pop, set, and embed actions.
- Literal matchers.
- Keyword sets.
- Operator tries.
- Byte classes.
- Delimited strings.
- Line comments.
- Block comments.
- Multiline prefixes.
- Heredoc-like dynamic end markers.
- Captures.
- Scope stack actions.
- Embedded grammars.
- Theme metadata hints.
- Explicit performance hints.

Native DSL rules compile to specialized runtime matcher kinds. Regex should be optional in native DSL, not foundational.

### 8.2 Full TextMate Support

Full TextMate support is required in v0.1.

The importer must support TextMate grammars written as:

- JSON.
- plist/XML.
- Legacy `.tmLanguage` bundles where practical.

The importer must support the TextMate grammar model:

- `scopeName`.
- `name`.
- `patterns`.
- `repository`.
- `include`.
- `$self`.
- `$base`.
- External grammar includes.
- Repository includes.
- `match`.
- `begin`.
- `end`.
- `while`.
- `contentName`.
- `captures`.
- `beginCaptures`.
- `endCaptures`.
- `whileCaptures`.
- Numeric captures.
- Named captures where supported by the source grammar style.
- Nested captures.
- `applyEndPatternLast`.
- Injections.
- Injection selectors.
- Embedded languages.
- `firstLineMatch`.
- Disabled or ignored metadata fields must be preserved in reports where relevant.

The regex layer must support TextMate/Oniguruma-style constructs used by real TextMate grammars, including:

- Literals.
- Character classes.
- POSIX-style classes where applicable.
- Unicode classes where applicable.
- Alternation.
- Capturing groups.
- Non-capturing groups.
- Named groups.
- Lookahead.
- Negative lookahead.
- Fixed-length lookbehind.
- Negative fixed-length lookbehind.
- Backreferences.
- Backreferences to begin captures in end patterns.
- Anchors including line anchors.
- `\G` behavior.
- Quantifiers.
- Lazy quantifiers.
- Atomic groups where applicable.
- Inline flags.
- Escapes used by Oniguruma/TextMate grammars.

The TextMate runtime must not reject valid TextMate grammars for being too hard to optimize. Unsupported constructs are implementation bugs.

Separate analysis reports may exist:

```bash
zhlc report-textmate-json grammar.tmLanguage.json --missing
```

Reports may identify which rules lower to direct matchers or regex programs, but they must not redefine what “TextMate support” means.

### 8.3 Sublime Syntax Importer

Sublime `.sublime-syntax` support is included in v0.1.

The importer should support:

- YAML syntax files.
- Variables.
- Contexts.
- `include`.
- `match`.
- `push`.
- `pop`.
- `set`.
- `embed`.
- `escape`.
- `branch` and `fail` where feasible.
- `prototype`.
- Inheritance/extension features where feasible.

Sublime grammars are structurally close to `zhl` contexts, so they should often lower more directly than TextMate grammars.

### 8.4 Optional Tree-sitter Overlay

Tree-sitter support is included in v0.1 as an optional overlay/backend, not as the default lexical highlighter.

Use cases:

- More precise highlighting for declarations and symbols.
- Semantic-ish overlays where a full language server is unavailable.
- Structural highlighting for languages whose lexical grammar is insufficient.
- Debug comparison against parser-aware highlighting.

The Tree-sitter path must not contaminate the core runtime dependency graph.

---
