# Serialize HTTP/1 requests per connection

Ploof allows at most one active HTTP/1 request on each connection. A client
may pipeline later requests, but Ploof preserves their bytes in bounded
connection or kernel buffers and does not parse and dispatch the next request
until the current Response is complete. When those buffers fill, socket
backpressure bounds further input instead of allocating a request queue.

The Linux runtime may complete up to 16 finite responses in one reactor turn
when nonblocking sends accept every byte. Intermediate responses use
`MSG_MORE`; partial or backpressured sends fall back to tracked io_uring
completion. This bound prevents one hot connection from starving the worker.
Application completion, observation, timeout, and request-slot release still
occur only after the kernel accepts the full response.

Keep-alive remains supported, and separate connections remain concurrent across
worker shards. Concurrent pipelined handlers would require multiple request
slots per connection, ordered response buffering, and more complex failure
semantics. The bounded send burst improves pipeline throughput without adding
that queue, so version one keeps deterministic ordering and one active request.

Ploof will not impose a default requests-per-connection count. Gin with Go and
Express with Node also default to unlimited reuse, and Ploof reinitializes the
same fixed request slot instead of accumulating per-request connection memory.
Idle and progress timeouts, protocol failures, graceful shutdown, and explicit
`Connection: close` still end a connection. A count cap would add reconnect
work without creating a missing memory bound, so applications should place one
at the edge proxy only when their deployment needs it.
