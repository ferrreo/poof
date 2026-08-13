# Support declared bounded request trailers

Ploof supports request trailers only with chunked transfer encoding and requires
the request head's `Trailer` field to declare every possible trailer name. An
actual trailer name must belong to that declaration; a declared field may be
absent. A `Trailer` declaration on any other request framing receives 400.

Trailer fields use the same strict grammar and ordered multi-value/raw access
model as request headers but remain a separate collection. Ploof rejects fields
whose meaning was needed before body completion, including framing, routing,
forwarding, authentication, cookies, request modifiers, and content format.
Version one's forbidden table is `Host`, `Content-Length`, `Transfer-Encoding`,
`Trailer`, `Connection`, `Keep-Alive`, `Proxy-Connection`, `TE`, `Upgrade`,
`Expect`, `Authorization`, `Proxy-Authorization`, `Cookie`, `Content-Encoding`,
`Content-Type`, `Content-Range`, `Forwarded`, `X-Forwarded-For`,
`X-Forwarded-Host`, `X-Forwarded-Proto`, `Via`, `Origin`, `Referer`, `Accept`,
`Accept-Encoding`, `Accept-Language`, `Cache-Control`, `Pragma`, `Range`,
`If-Match`, `If-None-Match`, `If-Modified-Since`, `If-Unmodified-Since`,
`If-Range`, and `Max-Forwards`. Declaration names are unique
case-insensitively. Up to 32 empty declaration-list members are ignored across
all physical `Trailer` lines; more receives 400. Malformed, forbidden,
undeclared, or independently trailer-over-limit input receives 400 and closes.
Exhausting the route's overall encoded-wire body limit still receives 413.
If the remaining encoded budget cannot fit the minimum legal chunk or trailer
suffix, the decoder returns 413 immediately instead of retaining a workspace
until another byte or timeout.

The standard limits are 8 KiB for the trailer section, 4 KiB for one line, 32
declared names, and 32 physical fields. Together with the nonzero chunk count,
they form one runtime comptime chunked-request profile. Section, line, declared
name, and physical field bounds are configurable up to their HTTP/1 hard
ceilings. Their wire bytes also consume the encoded-wire body limit. Buffered
handlers and middleware `after` phases see trailers after body completion;
streaming consumers receive them with the terminal body event. This matches Go
and Node's post-body availability while preventing late metadata from changing
decisions already made.

The HTTP/1 runtime stores chunk and trailer decoder state in a separate
startup-sized `chunked_workspace_slots` pool. One tagged slot reuses its storage
across chunk and trailer phases; the standard Zig 0.16 x86_64 layout is 9,736
bytes, while each request record carries only an optional `u16` slot index. A
request first leases its base application workspace. Typed endpoints also lease
their route workspace before head middleware for bounded JSON responses; legacy
byte and text routes defer that lease. A resulting chunked-body decision leases
the chunked workspace before `100 Continue`. A typed-endpoint head short circuit
can therefore compete only for its declared route class, never for a chunked
slot. Shortage aborts the pending application lifecycle when it began, receives
the same exact 503-and-close response as other workspace exhaustion, and never
sends 100.
The profile specializes request-head declarations, both decoder phases, and the
pooled state type. Each slot therefore consumes exactly
`@sizeOf(Receiver(profile))` startup bytes with no runtime profile branches or
allocations.

At trailer completion, `request.trailers.all(name)` exposes ordered, trimmed,
case-insensitive multi-value lookup and `request.trailers.raw()` exposes ordered
wire names and untrimmed values. Public views retain only the validated trailer
section and expose no internal decoder spans; malformed caller-forged sections
fail closed without unchecked indexing. The section borrows the chunked slot
through body handling, response middleware, transport completion, and `after`;
completion or abort clears the used state before returning the slot. Head
middleware and non-chunked requests always see an empty trailer view.

Sources: [RFC 9110 list syntax](https://www.rfc-editor.org/rfc/rfc9110.html#section-5.6.1.2),
[RFC 9110 trailer limitations](https://www.rfc-editor.org/rfc/rfc9110.html#section-6.5.1),
[Go request trailers](https://pkg.go.dev/net/http#Request), and
[Node message trailers][node-trailers].

[node-trailers]: https://nodejs.org/download/release/latest-v24.x/docs/api/http.html#messagetrailers
