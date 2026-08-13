# Use a bounded pipelined upload sink window

A multipart request can transfer ownership of up to four file chunks to
asynchronous sink work at once under the standard profile. A route can lower the
window to one or raise it at comptime to a hard ceiling of sixteen. Required
chunk buffers and completion descriptors come entirely from startup pools and
are included in that route's workspace budget.

The standard owned chunk is 16 KiB. A route configures chunk bytes independently
from the window at comptime, from one byte through a 1 MiB hard ceiling. These
two values live in the multipart upload profile so route workspace cost is exact
before startup. Changing either standard requires representative identity,
gzip, memory, and filesystem benchmark evidence.

The parser presents chunks in wire order with an absolute file offset. It can
continue intake while fewer than the declared number are pending and pauses
socket reads when the window is full. Sink completions may arrive out of order,
but Ploof does not invoke file-end or advance the logical consumer lifecycle
until every prior chunk has completed. Only one multipart part owns the window
at a time.

A synchronously consumed chunk is released immediately and does not occupy the
pending window. On the first asynchronous sink failure, Ploof stops intake,
cancels outstanding operations where supported, reaps every completion before
reusing buffers, enters the ADR 0083 abort path, and closes the connection when
request-body bytes remain.

No consumer can retain a chunk outside synchronous handling or an accepted
ownership transfer. Window-full duration, sink latency, cancellation, and
failure are instrumented by route and worker.

Each occupied window slot is an ADR 0092 write poller. Ploof retains its chunk
through short writes, cancellation, and final CQE reaping.

This permits useful `io_uring` write depth without an unbounded stream buffer.
Chunk size and window are independent benchmark dimensions; the fixed defaults
can change only with representative upload measurements.
