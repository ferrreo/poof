# Tree-sitter Overlay

Tree-sitter support is an optional overlay adapter API in `src/tree_sitter/root.zig`.
`zhl` does not bundle parser libraries, query runtimes, or C interop. Callers
run their parser, map query captures to `zhl.tree_sitter.Capture`, then apply
them over native zhl tokens with `applyOverlayLine`.

`zig build tree-sitter-example` runs `examples/tree_sitter_overlay.zig`, a
small parser-adapter overlay example covered by `zig build test`.
`zig build check-tree-sitter` runs `benchmark/tree_sitter.mjs`, which uses the
Node `tree-sitter` and `tree-sitter-javascript` packages to parse JavaScript,
map real query captures to overlay tokens, write
`benchmark/visual/tree_sitter_overlay.html`, and report setup, parse, and
overlay timings. This benchmark/dev proof is intentionally outside the core
runtime dependency graph.

Use `styleFromCaptureName("@function.builtin")` when the adapter has standard
Tree-sitter highlight capture names. Unknown names map to `.plain`, so callers
can override project-specific captures before emitting `Capture` values.

Adapters can also expose a tiny native boundary:

```zig
pub fn captures(self, line: []const u8, scratch: anytype) ![]const zhl.tree_sitter.Capture
```

Pass that adapter to `applyAdapterLine`. The adapter owns parser state and
scratch storage; `zhl` only validates and overlays the returned captures.

The overlay validates ordered native tokens and ordered, non-overlapping capture
ranges, rejects ranges past the line length, clips captures across native token
boundaries, fills plain gaps, and emits normal `zhl.Token` values with the
capture `style_id` and optional `language_id`.

This keeps the hot highlighter path native and allocation-free while allowing
parser adapters to refine lexical tokens where a project needs Tree-sitter.
