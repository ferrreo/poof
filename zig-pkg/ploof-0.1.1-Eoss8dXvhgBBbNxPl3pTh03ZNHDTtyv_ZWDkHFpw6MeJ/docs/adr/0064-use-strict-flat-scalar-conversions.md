# Use strict flat scalar conversions

Typed query and URL-encoded form binding converts each percent-decoded value
with a comptime-specialized function for its destination type. Ploof does not
trim whitespace, fold case, split collections inside a value, or retry another
type interpretation.

Byte slices used as typed text must contain valid UTF-8, including empty text;
applications needing arbitrary bytes use the raw query or form collection.
Integers accept one or more ASCII decimal digits, with one leading minus only
for signed destinations. Leading zeroes are allowed; a leading plus, whitespace,
non-decimal syntax, or overflow receives 400.

Floats accept finite decimal and exponent syntax, with an optional leading minus
and an optional exponent sign. NaN, infinity, hexadecimal forms, surrounding
whitespace, and overflow to a non-finite value receive 400. Booleans accept
exactly lowercase `true`, lowercase `false`, `1`, or `0`. Enums accept only an
exact case-sensitive tag name and never an integer ordinal.

Present empty numeric, boolean, enum, and other non-text values remain errors as
defined by ADR 0063. Each slice or array occurrence converts independently.
Built-in conversion failures produce the safe typed-binding 400 response with
bounded diagnostic class and field identity, never the submitted value.

An HTML checkbox bound directly to a boolean should send `value="true"`; an
unchecked checkbox is absent and can use a Zig default of `false`. Custom domain
scalars follow ADR 0065.

Typed multipart text fields reuse these conversions with the shorter callback
lifetime defined by ADR 0088.

This is narrower than Gin's general text conversions and more typed than
Express's string values, keeping every accepted spelling explicit.

Sources: [Gin 1.12 form mapping](https://github.com/gin-gonic/gin/blob/v1.12.0/binding/form_mapping.go)
and [Express `urlencoded`](https://expressjs.com/en/5x/api.html#express.urlencoded).
