# Use one strict HTTP/1 wire grammar

Ploof version one will accept only the exact HTTP/1.1 request-line shape
`method SP request-target SP HTTP/1.1 CRLF`. Method and field names must be
valid tokens; field names must be followed immediately by `:`. Every line uses
CRLF. Ploof rejects bare CR or LF, alternate request-line whitespace,
whitespace before a field colon, obsolete folded fields, NUL, and forbidden
control bytes. RFC-valid `obs-text` remains valid inside field values.

There is no lenient or insecure parser mode. A syntactically valid unsupported
HTTP version receives 505; malformed syntax receives 400 when enough of the
request is valid to answer safely. Either result closes the connection. A
single grammar avoids disagreement with an edge proxy, which RFC 9112 identifies
as a request-smuggling risk, and follows Node's secure-parser default rather
than exposing its opt-in insecure compatibility mode.

One mandatory request-head admission step runs after this wire parser and
before routing or middleware. It composes request-target, query, message
framing, `TE`, and request-trailer declaration validation. A failure dispatches
no request, emits a closing error response, and makes pipelined remainder bytes
unavailable for another interpretation on that connection.

Sources: [RFC 9112](https://www.rfc-editor.org/rfc/rfc9112.html) and
[Node HTTP parser configuration](https://nodejs.org/download/release/latest-v24.x/docs/api/http.html).
