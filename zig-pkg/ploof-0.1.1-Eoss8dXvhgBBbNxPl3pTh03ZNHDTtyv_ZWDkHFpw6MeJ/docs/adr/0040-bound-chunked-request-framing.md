# Bound chunked request framing

Ploof accepts syntactically valid HTTP chunk extensions and discards them; they
are hop-by-hop metadata and have no application API. Each chunk-size and
extension line is limited to 1 KiB, and the standard request limit is 65,536
non-terminal data chunks. The final zero `last-chunk` is a distinct grammar
element and does not consume that quota. The chunk count is nonzero and belongs
to the runtime's comptime chunked-request profile.
Every size line, extension, delimiter, data byte, and trailer byte consumes the
route's encoded-wire body limit before transfer decoding.

Chunk sizes use strict hexadecimal syntax with checked conversion. Invalid
syntax, arithmetic overflow, missing CRLF, an oversized chunk line, or an
exceeded chunk count receives 400 and closes. The decoded body limit remains
independent and is checked after transfer and content decoding. This retains
the chunk-extension behavior accepted by Go and Node while adding explicit CPU,
memory, and wire-byte bounds required by Ploof's fixed-capacity runtime.
Specialization selects `chunked.Decoder(profile.chunks_max)` at comptime; the
hot receive path has no profile branch.

Sources: [RFC 9112 chunk extensions](https://www.rfc-editor.org/rfc/rfc9112.html#section-7.1.1)
and [Go chunked parsing](https://go.dev/src/net/http/internal/chunked.go).
