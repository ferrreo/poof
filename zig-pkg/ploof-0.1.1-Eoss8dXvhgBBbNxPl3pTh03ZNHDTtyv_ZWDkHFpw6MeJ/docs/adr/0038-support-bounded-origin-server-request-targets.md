# Support bounded origin-server request targets

Ploof accepts origin-form request targets and the absolute-form that HTTP/1.1
origin servers are required to accept. Absolute-form is limited to `http` and
`https`, contains neither userinfo nor a fragment, and must have normalized
scheme and authority equal to the values produced by the listener's forwarding
profile. A mismatch receives 400 and closes instead of allowing a second
authority source to bypass proxy trust. Routing uses only the decoded path;
Ploof retains the complete raw target for explicit inspection.

Raw paths admit only RFC 3986 `pchar` bytes and `/`; raw queries admit only
`pchar`, `/`, and `?`. Every percent triplet must be complete and hexadecimal.
RFC URI grammar permits a raw semicolon, so target parsing accepts it; the query
parser then applies ADR 0039 and rejects a raw query semicolon as Ploof policy.

Authority syntax accepts RFC reg-names, IPv6 literals, IPvFuture, an optional
port from 0 through 65535, and the explicitly empty port normalized by HTTP URI
rules. Zone identifiers and userinfo are rejected. CONNECT requires a nonempty
numeric port even though ordinary Host and absolute-form authorities permit an
empty one.

Ploof also accepts asterisk-form only as `OPTIONS *`, which receives generated
server-wide capability behavior rather than entering the path route graph. An
asterisk with any other method receives 400. Authority-form is recognized only
with `CONNECT`, but version one returns 501 and closes because its Response API
does not expose a raw tunnel or connection-hijack contract.

This covers normal origin and reverse-proxy traffic while keeping forward-proxy
and tunnel behavior outside version one. Express relies on a separate Node
`connect` event for tunnels; Ploof similarly does not pretend a normal route
handler can become a byte tunnel.

Sources: [RFC 9112 request targets](https://www.rfc-editor.org/rfc/rfc9112.html#section-3.2)
and [RFC 3986 path and query syntax](https://www.rfc-editor.org/rfc/rfc3986.html#section-3.3).
