# Bound JSON parse memory

Typed JSON routes have a parse-memory limit independent of their decoded-body
byte limit. The standard profile allows 2 MiB of parse-owned memory alongside
the standard 1 MiB decoded body. Applications and individual routes can replace
it at comptime with another finite value; there is no unlimited sentinel.

Ploof parses retained decoded-body chunks without first making a contiguous
copy. An unescaped string contained wholly in one stable chunk borrows those
bytes. Escaped or cross-chunk strings, variable arrays, pointers, and dynamic
JSON nodes use a linear region in the request's preallocated workspace. The root
typed value and all parse-owned backing storage count toward the parse limit;
retained input chunks remain charged to the decoded-body limit.

Dynamic node layout follows ADR 0059.

Composition calculates the exact storage for the aligned typed root and the
minimum variable-container plan records required by every accepted document
shape. A smaller limit is statically impossible and fails decoder composition.
Pointer and conversion backing, additional plans, and other storage selected by
the JSON document remain runtime work: growth past the limit returns 413 before
handler execution and resets the partial workspace. The logical limit is backed
by startup-sized per-worker pools under ADR 0072 rather than reserved in full
for every connection; concurrent pool-exhaustion behavior is a separate
runtime-capacity decision.

Parsed slices and pointers remain valid through the handler and applicable
middleware `response` and `after` phases, then expire with the request slot.
Application work that outlives the request must transfer data into explicitly
owned storage. Ploof performs no general heap allocation for typed JSON.

Gin and Express allocate decoded graphs through their language runtimes without
an independent graph-memory limit. Ploof's separate limit bounds representations
whose Zig layout expands beyond their compact JSON bytes.

Sources: [Zig 0.16 typed JSON allocation](https://github.com/ziglang/zig/blob/0.16.0/lib/std/json/static.zig),
[Gin JSON binding](https://github.com/gin-gonic/gin/blob/v1.12.0/binding/json.go),
and [Express body-parser read path](https://github.com/expressjs/body-parser/blob/v2.2.1/lib/read.js).
