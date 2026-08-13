# Distinguish text and byte multipart fields

The standard multipart `.field` declaration means UTF-8 text. An absent part
`Content-Type` has the effective value `text/plain; charset=utf-8`. Explicit
`text/plain` with no charset or a case-insensitive UTF-8 charset is accepted.
Another media type or charset receives 415, and invalid field-content UTF-8
receives 400 before the field callback.

The `_charset_` part name is ordinary schema-controlled application data and
cannot alter this interpretation for later parts. Ploof performs no legacy
transcoding or stateful form-charset selection.

A route uses `.bytes_field` when an ordinary part intentionally contains
arbitrary bytes. That declaration applies no charset semantics; a syntactically
valid part media type remains untrusted metadata. Streamed file contents are
also arbitrary bytes, and their declared media type is metadata only. Neither
kind is sniffed. File media policy and content verification follow ADR 0090.

Decoded part names and text values must be valid UTF-8, while byte fields and
file chunks need not be. Every kind remains subject to the route's byte and
cardinality limits.

Nested multipart payloads follow ADR 0085: file and byte fields remain opaque,
while text fields reject that unsupported media type.

Field callback ownership follows ADR 0081.
Typed text conversion follows ADR 0088. Byte fields have no implicit scalar
conversion.

This matches modern browser UTF-8 forms while making binary ordinary fields
explicit and avoiding the multipart `_charset_` interpretation described for
legacy producers.

Sources: [RFC 7578 part content types](https://www.rfc-editor.org/rfc/rfc7578.html#section-4.4)
and [default charset convention](https://www.rfc-editor.org/rfc/rfc7578.html#section-4.6).
