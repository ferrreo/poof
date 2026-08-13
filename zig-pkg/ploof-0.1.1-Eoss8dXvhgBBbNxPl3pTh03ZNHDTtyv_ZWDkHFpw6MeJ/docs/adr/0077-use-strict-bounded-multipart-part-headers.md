# Use strict bounded multipart part headers

Every multipart part contains exactly one `Content-Disposition` field. Its
disposition type must be `form-data` and it must contain exactly one non-empty
`name` parameter. Filename parameters follow ADR 0078. A part can also contain
at most one syntactically valid `Content-Type` field.

Duplicate singleton fields, duplicate disposition parameters, malformed quoted
strings or escapes, invalid field-name tokens, embedded NUL or control bytes,
and obsolete folded lines reject the request with 400. Header parsing is
case-insensitive for field and parameter names but preserves values. It never
generically comma-joins repeated fields.

`disposition_parameters_max` has a standard value of 16 and a hard maximum of
64. Every `Content-Disposition` parameter counts, including an unknown
parameter that Ploof will discard. Crossing the configured count receives 413,
while configuration above the hard maximum is rejected at comptime. Duplicate
names are detected case-insensitively across every parameter and receive 400;
the request workspace sizes bounded deterministic duplicate detection to the
configured count, not the hard maximum.

Ploof rejects any `Content-Transfer-Encoding` part field and does not implement
quoted-printable, base64, or other per-part transfer decoding. Other
syntactically valid part headers remain bounded under ADR 0021 but are discarded
under ADR 0086. They cannot affect part boundaries, route-schema classification,
content decoding, or HTTP framing.

Part `Content-Type` interpretation for declared fields follows ADR 0080.
Unsupported part-header handling follows ADR 0086.
Declared-file media claims and acceptance policies follow ADR 0090.

This accepts normal browser-generated form data while removing folded and
alternate-transfer interpretations.

Sources: [RFC 7578 part disposition](https://www.rfc-editor.org/rfc/rfc7578.html#section-4.2)
and [deprecated transfer encoding](https://www.rfc-editor.org/rfc/rfc7578.html#section-4.7).
