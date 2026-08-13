# Use explicit response media types

Ploof never sniffs response bytes to select a media type. Typed helpers attach
deterministic defaults: JSON uses `application/json; charset=utf-8`, OTTB HTML
uses `text/html; charset=utf-8`, text uses `text/plain; charset=utf-8`, and raw
bytes or a generic stream use `application/octet-stream`. Empty and bodyless
responses omit `Content-Type`.

A file response, introduced in M12, uses an explicit media type when supplied.
Otherwise it looks up the final filename extension in Ploof's bounded static
media-type table and falls back to `application/octet-stream`; it never reads
file bytes for detection. The table lands with file responses in M12 rather
than as unused M2 machinery. Response middleware can replace the selected
media type before commitment.

Static media types are parsed and validated at comptime. Dynamic media types
use the same typed parser and return an error before response commitment. Header
injection validation from ADR 0046 still applies to the serialized field value.

Gin and Express response helpers also attach conventional types. Go's generic
writer can instead inspect the first 512 bytes when `Content-Type` is absent.
Ploof's explicit body variants remove that work and avoid data-dependent type
selection.

Sources: [RFC 9110 Content-Type](https://www.rfc-editor.org/rfc/rfc9110.html#section-8.3),
[Go `DetectContentType`](https://pkg.go.dev/net/http#DetectContentType),
[Express response helpers](https://expressjs.com/en/5x/api/response/), and
[Gin renderers](https://github.com/gin-gonic/gin/tree/v1.12.0/render).
