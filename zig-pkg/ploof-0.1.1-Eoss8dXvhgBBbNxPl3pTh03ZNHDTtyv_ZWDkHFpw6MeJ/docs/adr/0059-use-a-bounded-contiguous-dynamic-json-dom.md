# Use a bounded contiguous dynamic JSON DOM

Ploof provides an untyped, request-scoped `Json.Value` for routes that cannot
declare a fixed schema. It is a tagged union of null, boolean, number lexeme,
string, array, and object. Arrays are contiguous slices of values; objects are
contiguous slices of name/value members in input order.

Strings and number lexemes borrow stable input bytes when possible and otherwise
use the JSON parse arena. Number lexemes remain validated decimal text until an
explicit accessor converts them exactly to a requested integer or finite float.
Application-created numbers use a validating constructor rather than exposing
an unchecked raw-token variant.

Objects reject duplicate decoded names under ADR 0052. They provide ordered
iteration and exact, case-sensitive key lookup. Version one scans the contiguous
member slice and creates no per-object hash table. Typed decoding remains the
hot-route path; a lookup index is added only if representative benchmarks show
that its extra memory and construction work pay for themselves.

Accessors report a type or conversion error and never coerce strings, numbers,
booleans, null, arrays, or objects into one another. The dynamic graph obeys the
same body, depth, JSON parse-memory, and request-lifetime limits as typed JSON.
It can be passed to the bounded response encoder while that lifetime remains
valid.

This supplies Gin/Express-style schema-free handling without a general heap,
implicit `f64` rounding, or runtime hash maps on every parsed object.

Sources: [RFC 8259](https://www.rfc-editor.org/rfc/rfc8259.html)
and [Zig 0.16 dynamic JSON](https://github.com/ziglang/zig/blob/0.16.0/lib/std/json/dynamic.zig).
