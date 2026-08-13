# Use exact JSON field schemas

Typed JSON binding matches object names to Zig struct fields exactly and
case-sensitively. Ploof performs no automatic case folding or camelCase and
snake_case conversion. A type can declare comptime JSON field metadata that
renames selected fields; the same wire name applies to request decoding and
response encoding.

A struct field without a Zig default is required, including when its type is
optional. An optional type permits an explicit JSON `null`; a field default
permits absence. Thus `value: ?T = null` accepts missing and null, while
`value: T = default` accepts missing but still rejects null. Response encoding
continues in Zig declaration order using any renamed wire names.

Flat query and form binding reuse the default-based absence rule under ADR
0063, but those formats have no null token.

Schema construction rejects empty, invalid, or duplicate wire names and rename
collisions at comptime. Version one has no alternate input aliases. The route's
unknown-field policy is applied only after exact and renamed fields have been
resolved.

Directional field inclusion follows ADR 0057.

Go JSON decoding also supports explicit field names but falls back to
case-insensitive matching and leaves absent fields at their zero values. Ploof
uses Zig defaults to distinguish absence from null and prevent casing mistakes
without runtime reflection maps.

Sources: [Go JSON field behavior](https://pkg.go.dev/encoding/json),
[RFC 8259 object names](https://www.rfc-editor.org/rfc/rfc8259.html#section-4),
and [Zig 0.16 typed JSON](https://github.com/ziglang/zig/blob/0.16.0/lib/std/json/static.zig).
