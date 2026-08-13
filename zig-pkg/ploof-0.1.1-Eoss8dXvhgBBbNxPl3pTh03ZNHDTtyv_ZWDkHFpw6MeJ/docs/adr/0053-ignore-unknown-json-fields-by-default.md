# Ignore unknown JSON fields by default

Typed JSON binding ignores object fields absent from the destination Zig type
by default. An application can change its comptime default to reject, and an
individual route can override that policy. Reject mode returns the same safe 400
class as another typed binding mismatch before the handler runs.

Ignore mode skips an unknown value without materializing it into typed parse
memory, but it does not relax token validation. Its complete subtree still
obeys syntax, nesting, UTF-8, numeric, and body limits. Object-name tracking
still rejects duplicate known or unknown names, including decoded-equivalent
spellings.

Version one does not capture unknown members into an implicit extras map. A
route that needs arbitrary fields binds explicitly to Ploof's dynamic JSON
representation and remains subject to the same token rules.

This matches Go and Gin's default typed-decoding behavior and supports additive
client/server version skew. Strict routes retain an easy local opt-in without a
process-global decoder switch.

Sources: [Go `DisallowUnknownFields`](https://pkg.go.dev/encoding/json#Decoder.DisallowUnknownFields),
[Gin JSON binding](https://github.com/gin-gonic/gin/blob/v1.12.0/binding/json.go),
and [Express body-parser JSON](https://github.com/expressjs/body-parser/blob/v2.2.1/lib/types/json.js).
