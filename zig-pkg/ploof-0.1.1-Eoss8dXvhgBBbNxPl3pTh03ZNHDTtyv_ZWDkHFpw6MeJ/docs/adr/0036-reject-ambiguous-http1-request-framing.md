# Reject ambiguous HTTP/1 request framing

Every HTTP/1.1 request must contain exactly one valid `Host` field. It may
contain at most one `Content-Length`, whose trimmed value is one non-empty
unsigned decimal number, or at most one `Transfer-Encoding`, whose complete
trimmed value is the case-insensitive token `chunked`. Duplicate framing fields,
comma-separated length values, and a request containing both length and
transfer encoding receive 400 and close, even when repeated lengths agree.

A syntactically valid but unsupported transfer coding receives 501 and closes,
including a valid unsupported chain whose final coding is `chunked`. A
`chunked` coding with parameters, more than one `chunked` coding, or a
non-final `chunked` coding is invalid framing and receives 400 instead.
Without `Content-Length` or chunked transfer encoding, a request has no body;
Ploof never infers one from its method or from connection close. This is
deliberately stricter than Go, which accepts matching duplicate lengths and
removes a length when chunked encoding is present. Rejecting every ambiguous
case gives an edge proxy and Ploof fewer opportunities to disagree about the
next request boundary.

Sources: [RFC 9112 message body length](https://www.rfc-editor.org/rfc/rfc9112.html#section-6.3)
and [Go transfer parsing](https://go.dev/src/net/http/transfer.go).
