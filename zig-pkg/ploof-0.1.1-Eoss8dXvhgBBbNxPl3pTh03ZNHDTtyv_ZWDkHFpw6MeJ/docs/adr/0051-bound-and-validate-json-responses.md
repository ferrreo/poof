# Bound and validate JSON responses

`Context.json` completely encodes one value into startup-allocated,
worker-owned response storage before response commitment. The standard encoded
limit is 1 MiB per typed endpoint and is replaceable with the endpoint's
`response_json_bytes_max` comptime field; crossing it discards the partial
result and returns `ResponseBodyTooLarge`. Raising the limit enlarges only the
bounded request-workspace class required by routes that select that endpoint.
The runtime leases that selected class before head middleware, so `Context.json`
and the central error mapper use the same exact bound in head, body, and response
phases. A head response whose serialized bytes remain in this class retains the
lease through transport completion or abort. The lease remains even if response
middleware replaces the wire response, because middleware state and `after`
may still hold a view of the earlier JSON bytes.

The first JSON encode in a request may write directly into its exact source
region. Every later encode attempt uses disjoint staging before copying the
completed document back. This per-request taint survives caught encoder errors
and the head-to-body workspace rebind, so an earlier borrowed JSON view can be
used as input to a later response without source/destination aliasing.

The encoder allocates no framework heap memory and enforces a maximum nesting
depth of 64 in every build mode. It rejects circular references, invalid UTF-8
in Zig strings, non-finite floats, and malformed custom output. These failures
occur before commitment. Zig's `jsonStringify` hook remains supported and its
application errors propagate through the handler's error union while Ploof's
size, depth, and completed-document validation remain active.

Default output is minified UTF-8 in declaration order. `Context.jsonWith`
selects explicit comptime depth, whitespace, HTML-safe, and optionally tighter
encoded-size policy. Its encoded-size option cannot enlarge the endpoint's
preplanned capacity. Optional fields with
null values emit `null` unless explicitly omitted under ADR 0058; integers
remain exact decimal JSON numbers regardless of JavaScript's precision range;
non-ASCII text is not escaped. Only JSON-required characters are escaped by
default. Indented and HTML-safe output are explicit comptime options so their
branches disappear from the default specialization.

Custom encoding follows the constrained hook contract in ADR 0056.

Successful output becomes a fixed response with exact `Content-Length` and the
JSON media type from ADR 0050. Ploof never switches an oversized or generated
value to chunked output implicitly. Large arrays, NDJSON, or indefinite
generation require an explicit streaming response contract.

Gin and Express also materialize ordinary JSON before sending. Ploof adds
release-mode depth, cycle, UTF-8, numeric, and output-size guarantees that Zig
0.16's generic stringifier does not provide by itself.

Sources: [Zig 0.16 `Stringify`](https://github.com/ziglang/zig/blob/0.16.0/lib/std/json/Stringify.zig),
[Gin JSON renderer](https://github.com/gin-gonic/gin/blob/v1.12.0/render/json.go),
and [Express JSON response](https://github.com/expressjs/express/blob/v5.2.1/lib/response.js).
