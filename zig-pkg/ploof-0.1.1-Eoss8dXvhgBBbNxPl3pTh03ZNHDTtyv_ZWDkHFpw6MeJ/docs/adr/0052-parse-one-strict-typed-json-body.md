# Parse one strict typed JSON body

A route declaring a typed JSON body accepts `application/json` and
`application/*+json` media types. An absent or mismatched media type, or a
declared charset other than UTF-8, receives 415. Ploof parses the fully received
and content-decoded body retained under ADR 0018 directly from its stable chunks
rather than coalescing a second complete copy.

Routes accepting multiple body representations use ADR 0069's explicit decoder
table rather than automatic binding.

The parser requires exactly one complete JSON value with optional surrounding
JSON whitespace. An empty body, trailing non-whitespace, or a second value
receives 400. Any top-level JSON kind is valid when it matches the requested Zig
type; Ploof does not impose an object-or-array-only policy.

The standard maximum nesting depth is 64, configurable at comptime up to a hard
ceiling of 256 and enforced in every build mode. Invalid UTF-8, a byte-order
mark, invalid surrogate escapes, and duplicate names at any object level
receive 400. Duplicate comparison uses decoded names, so literal and escaped
spellings of the same name conflict.

JSON numbers bind without string coercion. Integer lexemes convert exactly to
the destination Zig integer or fail on overflow; finite floats must fit their
destination type. Dynamic JSON preserves numeric lexemes until the application
requests conversion instead of rounding all numbers through `f64`.

The untyped representation and lookup contract follow ADR 0059.

Client responses contain a fixed safe 400 description rather than body bytes,
parser internals, or field contents. Bounded diagnostics may retain an error
class and byte offset. Unknown-field policy and typed parse-memory capacity are
separate decisions.

Custom decoding follows the constrained hook contract in ADR 0056.

This is stricter than Gin and Express defaults that can collapse duplicate
names, coerce dynamic numbers, or accept additional top-level input. The strict
token layer ensures middleware and typed handlers observe one interpretation.

Sources: [RFC 8259 JSON](https://www.rfc-editor.org/rfc/rfc8259.html),
[RFC 6839 structured syntax suffixes](https://www.rfc-editor.org/rfc/rfc6839.html),
[Zig 0.16 scanner](https://github.com/ziglang/zig/blob/0.16.0/lib/std/json/Scanner.zig),
and [Zig 0.16 typed parser](https://github.com/ziglang/zig/blob/0.16.0/lib/std/json/static.zig).
