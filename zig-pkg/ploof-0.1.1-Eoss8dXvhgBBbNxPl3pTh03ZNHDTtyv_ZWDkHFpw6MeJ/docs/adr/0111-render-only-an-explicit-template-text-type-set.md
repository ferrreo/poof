# Render only an explicit template text type set

Plain template interpolation accepts `u8` arrays and slices as UTF-8 text,
booleans as exactly `true` or `false`, integers as ungrouped base-10 text, and
enums as their exact tag name. Invalid UTF-8 is a render error before response
commitment; Ploof never substitutes replacement characters.

Optionals require the `with` control form and never become implicit empty text.
Floats require a helper that states precision, rounding, and non-finite policy.
Structs, unions, maps, pointers as values, arbitrary bytes, and other
unsupported types fail at comptime. There is no reflection, debug printing,
locale lookup, or `std.fmt` fallback.

A custom scalar type may define an exact `formatText(self)` hook returning
`InlineText(N)` or a closed error union of that type. `N` is comptime-known; the
result carries its bytes inline, allocates nothing, is consumed immediately,
and is UTF-8-validated before the surrounding HTML context escapes it. Hook
errors join the route's closed error set under ADR 0110. `N` is nonzero and no
larger than the 64 KiB hard ceiling.

`Url`, `AssetRef`, `TrustedResourceUrl`, `TrustedHtml`, and browser data retain
their dedicated placement contracts and are not stringified through this path.
This prevents accidental debug output, hidden allocations, and formatting
policy changes from becoming application HTML.

Verification covers every integer width and boundary, booleans, enum tags,
valid and invalid UTF-8, unsupported-type diagnostics, formatter maximums and
errors, escape expansion, and absence of formatting allocations.
