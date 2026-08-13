# Own automatic response fields

Ploof emits a runtime-owned `Date` field on every final 2xx through 5xx
response and omits it from `100 Continue`. Each worker caches one formatted
HTTP date and refreshes it at most once per second through runtime timekeeping;
there is no per-response clock syscall or date formatting. Tests inject their
clock, but production cannot disable the field.

Ploof emits no `Server` or `X-Powered-By` identity by default. An application
can opt into a static identity field explicitly. Persistent HTTP/1.1 responses
omit `Connection`; the runtime emits `Connection: close` only when it will close
that connection. Version one does not emit `Keep-Alive`, `Via`, or `Alt-Svc`:
the edge proxy owns downstream protocol advertisement and intermediary
metadata.

One prepared-response close decision drives both serialized wire fields and
the transport disposition. The driver does not independently reconstruct that
decision from earlier admission state.

`Date` and the version-one edge-owned names are reserved from the generic
response-header API. Identity configuration, connection state, and future
protocol advertisement use typed configuration. Every automatic field consumes
the route's response-head byte and field limits.

In HTTP/1.1, application and representation fields precede runtime framing and
the optional `Trailer` declaration. `Date` follows those fields, then
the optional static `Server` identity, then `Connection: close` when present.
This fixed order has no semantic meaning but makes byte output reproducible.

Go and Node also generate `Date` automatically. Express additionally enables
`X-Powered-By: Express` by default. Ploof retains the protocol metadata while
avoiding a default framework fingerprint and repeated formatting work.

Sources: [RFC 9110 Date](https://www.rfc-editor.org/rfc/rfc9110.html#section-6.6.1),
[RFC 9110 Server](https://www.rfc-editor.org/rfc/rfc9110.html#section-10.2.4),
[Go `ResponseWriter`](https://pkg.go.dev/net/http#ResponseWriter),
[Node `sendDate`](https://nodejs.org/api/http.html#responsesenddate), and
[Express settings](https://expressjs.com/en/5x/api/application/#app.settings.table).
