# Own HTTP/1.1 response framing

Ploof exclusively owns HTTP/1.1 response framing and hop-by-hop fields.
Applications cannot insert `Content-Length`, `Transfer-Encoding`, `Trailer`,
`Connection`, `Keep-Alive`, `Proxy-Connection`, `TE`, or `Upgrade` through the
generic response-header API. A static field name is rejected at comptime; a
dynamic name returns a typed error before response commitment. Future protocol
upgrade support must use a dedicated typed contract rather than bypassing this
boundary.

After response middleware and content-coding selection, fixed wire bytes use an
exact `Content-Length`. This covers identity-coded byte, JSON, HTML, and file
responses. An unknown-length stream uses chunked transfer coding. A stream may
instead declare an exact wire length and use `Content-Length`; the runtime
counts its bytes. Declared response trailers require chunked framing. A typed
response option, not a raw header, requests connection closure.

An exact stream that attempts to exceed its length is stopped before the extra
byte is written. If it finishes short, the response remains incomplete. Either
violation is reported in the immutable transport outcome, closes the
connection, and forbids connection reuse. Ploof never sends both
`Content-Length` and `Transfer-Encoding` and never guesses framing from write
timing or an automatic buffering threshold.

The transport outcome distinguishes exact overrun, exact underrun, producer
failure, stalled write, peer abort, and framework cancellation from successful
completion and HEAD suppression. All failure variants are terminal and run
`after` once. To detect overrun without leaking a byte, the runtime polls once
more after the declared count with a one-byte canary capacity; completion is
accepted and any progress is classified as overrun before submission. Pending
keeps the canary phase live: a retained wake schedules another one-byte canary
poll rather than treating pending as completion.

This deliberately narrows the mutable-header freedom exposed by Gin and
Express while preserving their common fixed and streaming response workflows.
Gin delegates framing to Go's HTTP server, which already enforces declared
length overflow and prevents reuse after a short response; Ploof makes that
ownership visible in its typed API.

Sources: [RFC 9112 message body length](https://www.rfc-editor.org/rfc/rfc9112.html#section-6.3),
[Go `ResponseWriter`](https://pkg.go.dev/net/http#ResponseWriter),
[Go HTTP server framing](https://go.dev/src/net/http/server.go), and
[Gin response writer](https://github.com/gin-gonic/gin/blob/v1.12.0/response_writer.go).
