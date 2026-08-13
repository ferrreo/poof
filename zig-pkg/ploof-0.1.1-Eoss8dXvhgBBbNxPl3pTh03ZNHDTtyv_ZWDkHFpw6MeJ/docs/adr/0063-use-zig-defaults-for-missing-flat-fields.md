# Use Zig defaults for missing flat fields

Typed query and URL-encoded form fields use the same absence rule as typed JSON:
a field without a Zig default is required, including an optional or slice field.
A missing field with a default receives that default. Thus `limit: u16 = 50`
defaults only when absent and `age: ?u16 = null` represents an optional flat
field.

Query and URL-encoded form syntax have no textual null value. When an optional
field is present, its bytes must decode as its child type. A present empty value
remains an empty byte or text value when that destination permits emptiness;
for numeric, boolean, enum, and other non-text destinations it is a conversion
error and receives 400.

Built-in non-empty conversion follows ADR 0064.

Defaults never replace present empty, malformed, out-of-range, or otherwise
invalid values. Slices and fixed arrays apply the same rule to their occurrence
set: absence requires a field default, while presence is governed by ADR 0062
and every element must convert.

This distinguishes absence from user-provided data and prevents the zero-value
coercion common in permissive form binders from bypassing validation.

Source: [Gin 1.12 form mapping](https://github.com/gin-gonic/gin/blob/v1.12.0/binding/form_mapping.go).
