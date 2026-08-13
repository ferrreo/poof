# Constrain custom JSON codecs

A Zig type can opt into custom JSON representation with comptime-checked
`jsonParse` and `jsonStringify` hooks. The familiar Zig hook names are retained,
but Ploof supplies its own bounded typed decoder or encoder rather than an
unchecked byte reader or writer.

A decode hook consumes exactly one structured JSON value at its current
position. An encode hook emits exactly one structured JSON value. Hooks can
read or write structured scalars, containers, and nested values, but cannot
inject raw JSON fragments or access response chunks. Ploof therefore continues
to enforce UTF-8 validity,
duplicate-name rejection, nesting depth, exact numeric conversion, JSON parse
memory, cycle detection, and encoded response size across custom types.

Ploof invokes each decode hook once for each typed decode occurrence. It
materializes only the custom-hook subtree as a bounded structured value before
invocation, so its backing storage is an explicit parse-memory cost; ordinary
typed subtrees retain the direct decoder path. A hook consumes its root parser
once even if the parser value is copied. Structured cursors are repeatable
views; explicitly parsing the same cursor more than once requests more than one
conversion and can invoke a nested hook more than once. Cursors never expose raw
input bytes.

Decode hooks return only Ploof's closed representation-error set. Syntax,
shape, conversion, and hook failures produce the same safe 400 response as
other typed JSON failures; direct hook returns cannot impersonate framework
invariants or parse-memory exhaustion. Parser-originated resource errors retain
their normal classification. Application semantic validation remains handler
or middleware work. An encode type may declare a finite
`JsonApplicationError`; its `jsonStringify` return must be exactly `json.Error`
combined with that declared set. Without the declaration, the return must be
exactly `json.Error`. The two sets are disjoint, and template composition also
rejects application error names reserved by HTML rendering or response chunks.
Structured writer operations expose framework errors plus application failures
declared by the value being written; unrelated sibling hook types do not widen
one hook's signature.
This explicit split prevents a framework failure from impersonating an
application failure and prevents an undeclared hook failure from bypassing
composition checks. Because ordinary JSON and browser data blocks are fully
encoded before commitment, declared application failures reach the central
application-error mapper.

Hook presence, signature, complete declared error equality, framework-error
disjointness, and production of one value are checked at comptime where the
type makes that possible and otherwise before commitment or handler entry.
Built-in custom representations use the same contract. Ploof does not provide
a raw-output escape hatch through these hooks; pre-encoded JSON would require a
separate explicitly validated type and is outside this decision.

This keeps Zig's type-owned customization model while preventing custom codecs
from weakening route-wide JSON invariants.

Source:
[Zig 0.16 JSON stringifier](https://github.com/ziglang/zig/blob/0.16.0/lib/std/json/Stringify.zig).
