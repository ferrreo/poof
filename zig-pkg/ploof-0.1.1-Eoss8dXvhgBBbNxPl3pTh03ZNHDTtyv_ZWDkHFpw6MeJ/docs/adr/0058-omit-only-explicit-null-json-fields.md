# Omit only explicitly marked null JSON fields

JSON field metadata can mark an optional field `.omit_if_null`. When that
field's value is null, the encoder emits neither its object name nor its value.
The option is rejected at comptime on a non-optional field. Without it, null is
encoded explicitly as in ADR 0051.

Omission is output formatting only. It does not change whether the field is
accepted, required, or defaulted during decoding. Remaining fields preserve Zig
declaration order, and the generated encoder specializes the null test for the
schema at comptime.

Version one has no global omit-null switch and no broad `omitempty` or
omit-default rule. `false`, numeric zero, empty strings, and empty collections
remain visible values. If an application wants to omit one of those
conditionally, it constructs an optional response field as null or uses a
constrained whole-type codec hook under ADR 0056.

This provides an explicit equivalent to an absent Express object property
without importing Go's multi-meaning `omitempty` behavior into every field.

Sources: [Go `encoding/json` field options](https://pkg.go.dev/encoding/json#Marshal)
and [ECMAScript `JSON.stringify`](https://tc39.es/ecma262/multipage/structured-data.html#sec-json.stringify).
