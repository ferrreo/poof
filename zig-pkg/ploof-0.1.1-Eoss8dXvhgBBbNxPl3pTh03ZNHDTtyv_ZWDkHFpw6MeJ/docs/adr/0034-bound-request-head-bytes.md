# Bound request-head bytes

Ploof's standard request-head limits are 32 KiB for the complete request head,
8 KiB for the request line, and 8 KiB for any one header line. A request-line
overflow receives 414; a header-line or aggregate-header overflow receives 431.
Each value is configurable at comptime up to a 1 MiB hard ceiling, so larger
legitimate cookies or tracing metadata change the fixed memory plan before
startup rather than allocate unpredictably while parsing.

The standard profile also permits 128 physical header fields, configurable at
comptime up to a hard ceiling of 1,024. Exceeding the count returns 431 and
closes the connection. This bounds metadata slots and per-field parser work
even when an attacker sends many tiny fields.

The standard profile sits inside established comparison behavior: Express with
Node defaults to a 16 KiB aggregate limit, Gin with Go defaults to 1 MiB, and
nginx permits four 8 KiB large-header buffers with an 8 KiB maximum for one
request or header line. Ploof therefore accepts more aggregate metadata than
Express while matching a common edge proxy's line and aggregate scale.
The count similarly sits near HAProxy's 100-field and Envoy's 100-field
defaults while remaining below nginx's 1,000 and Node's 2,000.

Sources: [Node HTTP server](https://nodejs.org/download/release/latest-v24.x/docs/api/http.html),
[Go `DefaultMaxHeaderBytes`](https://pkg.go.dev/net/http#DefaultMaxHeaderBytes),
and [nginx large client header buffers](https://nginx.org/en/docs/http/ngx_http_core_module.html#large_client_header_buffers).
Header-count comparisons: [HAProxy](https://www.haproxy.com/documentation/haproxy-configuration-manual/new/latest/#tune.http.maxhdr),
[Envoy](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/core/v3/protocol.proto.html),
[nginx](https://nginx.org/en/docs/http/ngx_http_core_module.html#max_headers),
and [Node](https://nodejs.org/download/release/latest-v24.x/docs/api/http.html).
