# Embed request data as non-executable typed JSON

Ploof templates expose request-specific browser state only through a
compiler-owned JSON data-block directive. The directive takes a static unique
name and a typed value, then emits the complete
`<script type="application/json" id="...">...</script>` element. A named block
cannot occur on a repeating template path, and duplicate possible names in the
closed template graph fail at comptime.

The value uses Ploof's existing typed, depth-bounded and size-bounded JSON
encoder. It writes directly into bounded template output without an
intermediate allocation and accepts no raw JSON fragment. In this HTML-safe
mode, JSON strings additionally encode U+003C, U+003E, U+0026, U+2028, and
U+2029, ensuring view data cannot form `</script>` or change HTML token
structure.

Application-owned external or embedded JavaScript locates the block, reads its
text, and invokes `JSON.parse`. Templates cannot interpolate a value into an
executable script expression such as `const state = {{value}}`. This costs one
browser lookup and JSON parse but prevents request data from becoming
JavaScript source while retaining server-rendered hydration support.

Verification covers every JSON scalar and container, mixed-case closing-tag
payloads, comments and entity-like inputs, Unicode separators, maximum encoded
size and depth, duplicate block names, loop placement, structure preservation,
and codec/template fuzzing.
