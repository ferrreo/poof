# Reject unknown multipart parts by default

A multipart part whose exact decoded name is absent from the route's ADR 0075
schema rejects the request with 400 by default. Ploof stops parsing, invokes
the ADR 0083 abort path for every consumer or sink already started by this
request, and closes the connection when body bytes remain unread.

A route can explicitly select `.ignore_unknown(max_part_bytes)` with a finite
byte bound. The parser then streams unknown content to discard without
buffering or callbacks. Each such part still consumes header, part-count,
unknown-part-byte, and total-body limits; exceeding a configured bound receives
413. It never counts as an admitted file, creates storage, or enters a hidden
map.

Filename and media-type metadata cannot change unknown-name handling. Generic
dynamic-part consumption is a separate explicit contract rather than the
standard schema fallback.

Multipart differs from JSON and flat form defaults because an unknown part can
carry a large stream or trigger storage side effects. Requiring admission by
name matches Multer's rejection of unexpected declared file fields and makes
discard bandwidth deliberate.

Source: [Multer upload errors](https://expressjs.com/en/resources/middleware/multer/#error-handling).
