# Use typed extensible response statuses

Ploof exposes a non-exhaustive integer-backed `Status` type with named constants
for standard HTTP status codes. A final Response accepts any value from 200
through 599, including unregistered extension codes. Static invalid values fail
at comptime; `Status.fromInt` validates dynamic input and returns
`InvalidStatus` before response commitment.

Informational statuses remain outside the final Response contract. Version one
emits `100 Continue` through protocol handling as defined by ADR 0024; future
provisional responses require a separate typed API.

HTTP/1.1 serialization uses the canonical reason phrase for a known status and
an empty reason phrase for an unknown extension status, retaining the mandatory
space after the three-digit code. Applications cannot supply custom reason
text. Reason phrases are ignored by clients and absent from HTTP/2 and HTTP/3,
so keeping them out of the application contract preserves the protocol-neutral
Response API.

Gin and Express accept integer status codes and their underlying runtimes supply
standard reason text. Ploof keeps extension-code support while adding early
range validation and named Zig values.

Sources: [RFC 9112 status line](https://www.rfc-editor.org/rfc/rfc9112.html#section-4),
[RFC 9110 status codes](https://www.rfc-editor.org/rfc/rfc9110.html#section-15),
[Go `StatusText`](https://pkg.go.dev/net/http#StatusText), and
[Node HTTP response](https://nodejs.org/api/http.html).
