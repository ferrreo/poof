# Use exact shared flat-field names

Typed query and URL-encoded form binding match a decoded name to its Zig struct
field exactly and case-sensitively. Ploof performs no automatic case folding or
camelCase and snake_case conversion.

A type can declare flat-field comptime metadata that renames selected fields.
The same flat wire name applies to both `Query(T)` and `Form(T)`. Applications
whose query and form contracts use different names define separate DTOs.

Version one has no alternate input aliases, dotted-path expansion, or bracket
interpretation. Metadata construction rejects empty names, invalid UTF-8,
duplicate wire names, and rename collisions at comptime. Binding uses the
generated schema directly without runtime reflection or a field-name map.

This mirrors ADR 0055's exact JSON naming while keeping JSON and flat metadata
separate so one type can represent intentionally different media contracts.

Source: [Gin 1.12 form mapping](https://github.com/gin-gonic/gin/blob/v1.12.0/binding/form_mapping.go).
