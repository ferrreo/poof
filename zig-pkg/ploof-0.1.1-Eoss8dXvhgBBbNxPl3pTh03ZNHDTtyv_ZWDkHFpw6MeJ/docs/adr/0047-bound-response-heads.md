# Bound response heads

Every Ploof route uses a comptime response-head limits profile. The standard
profile allows a 16 KiB complete serialized head, an 8 KiB physical field line,
and 64 physical fields. The complete count includes the status line, all
application, middleware, and runtime fields, framing fields, every CRLF, and the
final empty line.

An application can replace the standard profile and an individual route can
override it inline. The hard protocol ceilings are 1 MiB and 1,024 physical
fields; there is no unlimited sentinel. A route whose static fields cannot fit
fails composition at comptime. Dynamic insertion that would exceed a byte,
line, or count bound returns `ResponseHeadTooLarge` before commitment.

The logical byte limit does not reserve an equal buffer for every connection.
Response-head storage comes from startup-sized per-worker pools; their sizing
and exhaustion behavior are separate runtime decisions. Applications must also
configure the edge proxy to accept every legitimate Ploof profile because its
upstream response limit can be smaller.

Gin and Express do not impose an equivalent application response-head bound,
leaving memory and the HTTP runtime or proxy as the effective limit. Ploof's
explicit profile keeps work and memory planning bounded while retaining an
inline override for cookie-heavy or metadata-heavy routes.

Sources: [nginx proxy response buffer](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_buffer_size),
[HAProxy buffer size](https://docs.haproxy.org/3.2/configuration.html), and
[Caddy response-header limit](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy#the-http-transport).
