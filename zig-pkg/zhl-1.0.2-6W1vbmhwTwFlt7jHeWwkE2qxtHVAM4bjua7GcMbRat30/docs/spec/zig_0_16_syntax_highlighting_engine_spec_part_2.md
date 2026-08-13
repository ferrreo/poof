## 9. TextMate Compatibility Model

Full TextMate support requires both import compatibility and runtime semantic compatibility.

### 9.1 Compatibility Target

`zhl` should target the behavior expected by TextMate grammars as used in modern editors. The main compatibility references are:

- TextMate language grammar behavior.
- VS Code TextMate grammar usage.
- `vscode-textmate` behavior for differential tests.
- Real-world grammar suites.

When these disagree, `zhl` should:

1. Prefer documented TextMate semantics where clear.
2. Prefer VS Code behavior for VS Code-oriented grammars where TextMate behavior is ambiguous.
3. Expose diagnostic reports for known divergences.
4. Record differences in grammar compile reports.

### 9.2 Rule Priority

The runtime must preserve TextMate-style priority:

1. Search starts at the current byte position within the current line.
2. The earliest match wins.
3. If multiple rules match at the same position, grammar order wins.
4. Active `end` and `while` rules participate according to TextMate semantics.
5. `applyEndPatternLast` changes begin/end precedence where specified.
6. Includes and injections must preserve the effective priority order computed by the importer.

### 9.3 Begin/End/While Stack

TextMate `begin`/`end` and `while` patterns map to runtime frames.

A frame stores:

- Active context.
- Scope stack.
- End matcher.
- While matcher.
- Captures needed by dynamic end patterns.
- TextMate metadata needed for exact behavior.

Dynamic captures are stored in bounded scratch/state memory. If a capture exceeds configured bounds, the runtime returns an explicit overflow error or follows the configured error policy.

### 9.4 Injections

v0.1 must support TextMate injections.

`zhlc` should compile injection selectors ahead of time into effective rule lists. Runtime selector matching should not happen in the hot path.

The compiler should:

- Parse injection selectors.
- Resolve injected grammars.
- Compute effective injection points.
- Merge injected rules into compiled contexts.
- Preserve priority semantics.
- Emit debug reports explaining injection placement.

### 9.5 Embedded Languages

Embedded grammars should compile into context transitions with a grammar id and scope stack bridge.

The runtime should support:

- HTML with embedded CSS/JavaScript.
- Markdown fenced code blocks.
- Template languages.
- Language-specific heredoc rules.

Embedded-language token output should optionally include a language id for editor integrations.

---

## 10. Regex Strategy

The regex system is a compiler pipeline plus a regex VM.

There is one TextMate execution path: compile every supported rule to the fastest generic matcher that preserves semantics. Literal, keyword, deterministic regex, dynamic-end, and regex-VM representations are internal compile results, not user modes.

The regex VM must satisfy:

- Regex programs are compiled before runtime.
- Matching uses caller-provided scratch.
- No heap allocation during `highlightLine`.
- Bounded recursion or explicit VM stack.
- Configurable step limits for pathological input.
- Capture slots are caller-provided and bounded.
- Errors are explicit.

---

## 11. Native Matcher Set

The v0.1 matcher set should include:

```zig
pub const MatcherKind = enum(u8) {
    literal,
    literal_set,
    keyword_set,
    operator_trie,
    byte_class,
    byte_class_run,
    line_comment,
    block_comment,
    delimited_string,
    multiline_prefix,
    number,
    dfa,
    anchored_dfa,
    tagged_dfa,
    dynamic_literal_end,
    dynamic_regex_end,
    regex_vm,
};
```

Specialized matcher behavior:

```text
line_comment(prefix)
  match prefix, consume to EOL

block_comment(open, close, nesting_policy)
  consume until close; optionally support nesting

delimited_string(open, close, escape)
  consume with SIMD scan for close or escape

multiline_prefix(prefix)
  match prefix and consume to EOL

keyword_set(words, boundary)
  scan identifier and check trie/perfect hash

operator_trie(operators)
  choose longest operator match

number(format_set)
  scan grammar-declared numeric forms with shared byte predicates

dynamic_literal_end(capture)
  optimized heredoc-style dynamic line end

regex_vm(program)
  execute precompiled Oniguruma-compatible bytecode
```

The compiler should always prefer the cheapest semantically equivalent matcher.

---

## 12. Hot-Path Scanning Algorithm

Each context has a precomputed start-byte mask and rule buckets.

```text
while i < line.len:
    next = simdFindNextInterestingByte(line, i, context.start_mask)

    emit default token from i..next if needed
    i = next

    candidates = context.bucket[line[i]]
    best = findBestMatch(candidates, line, i, state, scratch)

    if best:
        apply action:
            emit token/captures
            push context
            pop context
            update scope stack
            update dynamic captures
            update state fingerprint
            i = best.end
    else:
        i += 1
```

This avoids trying every rule at every byte. Most source lines contain long runs of ordinary text, so the scanner should jump between interesting bytes.

Important invariants:

- Token starts are monotonically increasing.
- Token ends never exceed `line.len`.
- Zero-length matches are handled explicitly to avoid infinite loops.
- End/while matchers for the active frame participate in candidate selection.
- Captures emit nested spans without allocating.

---

## 13. SIMD Plan

Use Zig’s portable vector support first, with optional target-specialized backends later.

Core SIMD primitives:

```zig
pub fn indexOfAnyByte(
    comptime needles: []const u8,
    haystack: []const u8,
    start: usize,
) usize;

pub fn findNextInteresting(
    mask: ByteMask256,
    haystack: []const u8,
    start: usize,
) usize;

pub fn scanAsciiWhitespace(haystack: []const u8, start: usize) usize;

pub fn scanAsciiIdentifier(haystack: []const u8, start: usize) usize;

pub fn scanUntilByte(
    comptime byte: u8,
    haystack: []const u8,
    start: usize,
) usize;
```

Generated grammar tables should expose masks like:

```zig
const interesting_main = ByteMask256.fromBytes(.{
    '/', '"', '\'', '@', '\\',
    '0'...'9',
    'A'...'Z',
    'a'...'z',
    '_',
    '{', '}', '(', ')', '[', ']',
    '+', '-', '*', '%', '=', '<', '>', '!', '&', '|', '^', '~', '?', ':', ';', '.', ',',
});
```

Portable vector implementation shape:

```zig
const std = @import("std");

const VecLen = std.simd.suggestVectorLength(u8) orelse 16;
const Vec = @Vector(VecLen, u8);
```

For v0.1, prefer portable vectors plus scalar fallback. Add x86/aarch64-specific movemask paths only if profiling proves they are worth the maintenance cost.

---

## 14. Comptime Strategy

`zhlc --emit-zig` should generate static Zig modules.

Generated grammar shape:

```zig
pub const grammar = zhl.Grammar{
    .name = "Zig 0.16",
    .scope_root = 1,
    .contexts = &contexts,
    .rules = &rules,
    .matchers = .{
        .literals = &literals,
        .keyword_sets = &keyword_sets,
        .dfas = &dfas,
        .regex_programs = &regex_programs,
    },
    .scopes = .{
        .names = &scope_names,
        .stacks = &scope_stacks,
    },
    .context_start_masks = &context_start_masks,
    .context_rule_buckets = &context_rule_buckets,
};
```

Precompute before runtime:

- Scope string table.
- Scope ids.
- Scope-stack interning.
- Theme selector trie.
- Style id for each scope-stack state.
- Keyword tries or perfect hashes.
- Operator tries.
- Byte-class tables.
- DFA transition tables.
- Tagged capture plans.
- Regex VM bytecode.
- Context start-byte masks.
- Rule buckets by first byte.
- Minimum and maximum match lengths.
- State fingerprint metadata.
- Injection-expanded contexts.
- Embedded grammar bridges.

Then specialize at comptime:

```zig
const ZigHighlighter = zhl.Engine(zig_0_16.grammar, .{
    .simd = .auto,
    .emit_style_ids = true,
});
```

This lets Zig inline context-specific dispatch and eliminate unused matcher paths for grammars that do not need them.

---

## 15. Incremental Highlighting

Use a line-state model.

A tokenizer processes each line with the previous line’s end state. After an edit, the document retokenizes from the changed line until the new outgoing state equals the old outgoing state.

```zig
pub const Document = struct {
    line_states_in: []State,
    line_states_out: []State,
    line_tokens: []TokenRange,
    token_arena: TokenArena,

    pub fn edit(self: *Document, change: TextChange) !DirtyRange;
    pub fn rehighlight(self: *Document, first_line: u32) !DirtyRange;
};
```

Algorithm:

```text
rehighlight from changed line
for each line:
    old_out = line_states_out[line]
    new_out = highlightLine(line, current_state, scratch, sink)

    store tokens
    store new_out

    if new_out == old_out and line is past edited region:
        stop

    current_state = new_out
```

Document cache allocation is allowed during document creation or resize, but not during the line-highlighting hot path.

---

## 16. Token Format

Use compact binary tokens by default:

```zig
pub const PackedToken = packed struct(u64) {
    start: u32,
    style_id: u16,
    flags: u16,
};
```

The end of token `i` is token `i + 1`’s start, or the line length for the last token.

Diagnostic token output can include richer token data:

```zig
pub const DebugToken = struct {
    start: u32,
    end: u32,
    scope_stack_id: ScopeStackId,
    scope_names: []const []const u8,
    style_id: StyleId,
    language_id: u16 = 0,
};
```

Token streams should support:

- Compact editor rendering.
- ANSI output.
- HTML output.
- Debug scope dumps.
- Snapshot testing.
- Differential comparison.

---

## 17. Theme System

Theme resolution must happen before highlighting.

Pipeline:

```text
.tmTheme / VS Code theme JSON
        ↓
scope selector parser
        ↓
selector trie
        ↓
resolved style for every interned scope stack
        ↓
style_id in hot-path token
```

Runtime token emission should usually be:

```zig
sink.emit(.{
    .start = start,
    .end = end,
    .style_id = precomputed_style_id,
});
```

Requirements:

- No scope selector matching during `highlightLine`.
- No string comparison during token emission.
- Scope stacks remain available for debug and editor features.
- Theme changes can rebuild the style table without recompiling the grammar where possible.

---

## 18. Zig 0.16 Native Grammar

Ship `zhl-grammars/zig_0_16.zig` as a native hand-tuned grammar.

Zig 0.16 source grammar rules:

```text
comments:
  ///   comment.line.documentation.zig
  //!   comment.line.documentation.container.zig
  //    comment.line.double-slash.zig

strings:
  "..."       string.quoted.double.zig
  'x'         constant.character.zig
  \\...       string.quoted.multiline.zig

identifiers:
  [A-Za-z_][A-Za-z0-9_]*

builtins:
  @[A-Za-z_][A-Za-z0-9_]*

keywords:
  generated from Zig 0.16 language reference keyword list

numbers:
  decimal, binary, octal, hex, floats, exponents, underscores

operators:
  trie over Zig operators, longest-match first
```

Recommended Zig scopes:

```text
source.zig
comment.line.double-slash.zig
comment.line.documentation.zig
comment.line.documentation.container.zig
string.quoted.double.zig
string.quoted.multiline.zig
constant.character.zig
constant.numeric.integer.zig
constant.numeric.float.zig
keyword.control.zig
keyword.operator.zig
storage.type.zig
storage.modifier.zig
support.function.builtin.zig
entity.name.function.zig
entity.name.type.zig
variable.other.field.zig
punctuation.definition.string.begin.zig
punctuation.definition.string.end.zig
punctuation.separator.zig
invalid.illegal.zig
```

v0.1 should keep Zig highlighting primarily lexical, with cheap context-sensitive improvements:

- Function name after `fn`.
- Container names before `= struct`, `= union`, `= enum`, or `= opaque`.
- Field access after `.`.
- Builtins after `@`.
- Labels before `:` where unambiguous.
- Error set names and payload captures where cheap.

Do not require a full Zig parser for v0.1 highlighting correctness.

---
