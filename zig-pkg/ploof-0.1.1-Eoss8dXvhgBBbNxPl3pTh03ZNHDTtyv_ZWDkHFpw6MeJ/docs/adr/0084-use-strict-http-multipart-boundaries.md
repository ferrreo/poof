# Use strict HTTP multipart boundaries

A `multipart/form-data` media type must contain exactly one `boundary`
parameter. Ploof applies normal quoted-string decoding, then requires one to
seventy ASCII bytes from the RFC 2046 boundary character set, with no trailing
space. A missing, duplicate, empty, malformed, or longer value receives 400. A
route can lower its accepted boundary length; exceeding that valid route limit
receives 413, and comptime configuration above the protocol maximum is rejected.

Boundary delimiter lines require CRLF. Ploof accepts RFC transport padding made
only of spaces and horizontal tabs. It accepts and discards preamble before the
first delimiter and epilogue after the closing delimiter, but every discarded
byte consumes the decoded total-body limit. The parser consumes epilogue through
the HTTP message-body end rather than treating the MIME close as HTTP framing.

`delimiter_transport_padding_bytes_max` has a standard value of 64 bytes and a
hard maximum of 1,024 bytes. While resolving a delimiter candidate, crossing
the configured padding limit receives 413; configuration above the hard maximum
is rejected at comptime. The request workspace reserves the configured padding
size, not the hard maximum.

Within that resource bound, a boundary candidate becomes a delimiter only when
the complete boundary is followed by valid transport padding and CRLF, or by
the closing `--`, optional padding, and either CRLF or the exact message-body
end. Otherwise the candidate, including its preceding CRLF, remains part data.
A missing closing delimiter, bare-LF delimiter, invalid suffix, or truncated
multipart body receives 400 and aborts the ADR 0083 upload transaction.

This follows the MIME grammar while applying HTTP's CRLF requirement. Go's MIME
reader also accepts LF-only multipart input for robustness; Ploof deliberately
does not copy that non-HTTP tolerance. Browser and conforming HTTP generators
use the strict form.

Sources: [RFC 2046 section 5.1.1](https://www.rfc-editor.org/rfc/rfc2046.html#section-5.1.1),
[RFC 7578 section 4.1](https://www.rfc-editor.org/rfc/rfc7578.html#section-4.1),
and [RFC 9110 section 8.3.3](https://www.rfc-editor.org/rfc/rfc9110.html#section-8.3.3).
