# Use ordered bounded response headers

Ploof stores response header fields in a fixed-capacity ordered multivalue
collection rather than a heap-backed hash map. Field lookup is
case-insensitive. Static names are normalized at comptime and dynamic names are
normalized once before insertion; HTTP/1.1 serialization always uses lowercase
names so the internal representation can also serve future HTTP/2 and HTTP/3
backends.

The generic API exposes familiar `set`, `append`, and `remove` operations.
`set` replaces all values for a name at its existing position, `append` adds one
physical field line, and `remove` removes every value for a name. Serialization
preserves deterministic insertion order and never generically joins repeated
values with commas. In particular, each `Set-Cookie` remains a separate field
line.

A comptime field-semantics table rejects `append` for known singleton fields
and drives typed helpers for structured list fields such as `Vary`. Explicitly
appended unknown extension fields remain separate and ordered. Framing and
hop-by-hop names remain reserved under ADR 0044 regardless of which generic
operation is requested.

Static invalid names and values fail at comptime. Dynamic names must satisfy the
HTTP token grammar, and dynamic values reject CR, LF, NUL, and control bytes;
failure returns `InvalidHeader` before response commitment. This prevents
response splitting without adding a separate escaping mode.

Lookup and indexed field slices borrow the collection's fixed storage and are
invalid after its next successful mutation. `set` and `remove` reject input
slices that overlap that storage before changing anything; this avoids a hidden
scratch allocation and prevents compaction from changing the key or value being
applied. `append` may copy a currently borrowed value because it writes only
after the active storage range.

HTTP/1.1 serialization emits application fields in insertion order. A supplied
`Content-Type` keeps that position; otherwise its typed default follows the
application fields. Runtime framing and negotiated `Trailer` follow, then
cached `Date`, optional static `Server`, and optional `Connection: close`, in
that order. Protocol semantics do not depend on field order, but deterministic
bytes keep tests and benchmarks stable.

This keeps Express's `set` and `append` and Go's `Set` and `Add` workflows while
making ordering, duplicate handling, and allocation bounds explicit.

Sources: [RFC 9110 field lines](https://www.rfc-editor.org/rfc/rfc9110.html#section-5.2),
[RFC 9110 field values](https://www.rfc-editor.org/rfc/rfc9110.html#section-5.5),
[Express response headers](https://expressjs.com/en/5x/api/response/),
[Go `Header`](https://pkg.go.dev/net/http#Header), and
[Node HTTP header validation](https://nodejs.org/api/http.html).
