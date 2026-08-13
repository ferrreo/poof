# Use bounded progress-aware timeouts

Every Ploof listener will use a configurable timeout profile with no disabled
or unlimited duration sentinel. The first request head has a 10-second absolute
deadline from accept. On a reused connection, Ploof allows 60 seconds of
keep-alive idleness and, after the first new byte, 10 seconds to finish the
request head. A head timeout produces 408 only when a valid response can be sent
safely; every timeout closes the connection.

Request bodies have a 60-second network-inactivity timeout. It resets only on
actual input progress and is suspended while Ploof itself applies bounded
upload-consumer backpressure. Queued response bytes have a 60-second
stalled-write timeout. The write timer is not active while a streaming
application has no bytes queued. Bodies and streaming Responses have no total
duration deadline; their byte limits and progress timers provide the bounds
without breaking long uploads, downloads, or event streams.

A streaming producer that returns pending leaves no write timer armed and is
not periodically polled. Its generation-scoped wake handle publishes into one
bounded worker-local wake inventory. Wake publication racing the transition to
pending is retained by an atomic bit and observed before the worker sleeps.
Once woken, the normal response byte and stalled-write limits resume. Repeated
wakes coalesce; stale generations do not revive a completed or aborted stream.

Canceling the prior write timer is asynchronous. The request records both the
exact timer token and its cancel-operation token, and does not claim a retained
producer wake until terminal CQEs for both have been consumed. This permits at
most one parked timer-cancel pair and prevents a producer alternating progress
and pending from filling the bounded connection operation table while the
kernel delays cancellation completions.

Each stream-enabled worker owns one nonblocking eventfd, one persistent
io_uring poll, and one bounded ready-bit inventory for every request slot. A
two-level nonempty-word bitmap snapshots only ready leaf words into stable
worker storage, and dispatch iterates their set bits. Sparse notification work
therefore stays proportional to ready producers rather than configured request
capacity.
Finite-only application graphs compile this subsystem out. Request-gzip
decoder threads retain their separate proven eventfd lifecycle: sharing it
would couple stream publishers to gzip pool join, drain, and close ownership.
The two sources use distinct reserved reactor slots. Consolidation into a
common worker signal hub is deferred unless paired ReleaseSafe and ReleaseFast
measurements show that the extra descriptor or poll has material cost.

Connection operation sequences are 16-bit fields in the fixed 64-bit reactor
token. Before submission the connection checks the backend's bounded active
token table and skips any candidate whose complete raw identity is still live.
This keeps a long-lived connection from reusing an in-flight timeout, cancel,
send, or receive identity when its sequence wraps.

These defaults deliberately form a production-safe middle ground rather than
copying one replacement target. Gin's basic server inherits Go's unlimited
timeouts, while Gin's production example uses 10-second read and write limits.
Express inherits Node's 60-second header, 300-second whole-request, 5-second
keep-alive, and unlimited general socket timeout defaults. Ploof's 60-second
progress limits also match nginx's body-read and response-write defaults. Each
value remains easy to change per listener, but an application must choose a
finite positive duration.

Sources: [Gin server configuration](https://gin-gonic.com/en/docs/server-config/),
[Go `http.Server`](https://pkg.go.dev/net/http#Server),
[Express `app.listen`](https://expressjs.com/en/5x/api/application/),
[Node HTTP server](https://nodejs.org/download/release/latest-v24.x/docs/api/http.html),
[nginx client body timeout][nginx-body-timeout],
and [nginx send timeout](https://nginx.org/en/docs/http/ngx_http_core_module.html#send_timeout).

[nginx-body-timeout]:
  https://nginx.org/en/docs/http/ngx_http_core_module.html#client_body_timeout
