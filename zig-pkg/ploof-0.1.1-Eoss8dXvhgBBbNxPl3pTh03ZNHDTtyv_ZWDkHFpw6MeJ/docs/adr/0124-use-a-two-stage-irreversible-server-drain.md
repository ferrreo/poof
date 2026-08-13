# Use a two-stage irreversible server drain

One server has the irreversible public lifecycle `starting`, `ready`,
`draining`, and `stopped`; startup may instead end in `failed`. Repeated or
concurrent shutdown requests are idempotent and can only advance that state. A
stopped handle cannot restart. Readiness becomes true only after ADR 0123's
startup checks and every worker listener are ready, and becomes false as the
first action of drain.

The normal library API returns a `Server` handle and never installs process
signal policy or terminates the process. Its shutdown operation accepts a
finite grace duration and forced-cancellation duration. The convenience runner
blocks SIGTERM and SIGINT before creating threads and consumes them through
`signalfd`; the first signal begins drain and the second skips any remaining
grace and begins forced cancellation. It does not install an asynchronous
signal handler.

Drain cancels and fully reaps each pending accept, then closes each listener.
An accept completion racing with the transition is closed without dispatch.
Idle connections and connections with only a partial request head close
immediately. A request whose complete head was already admitted may finish its
body, handler, response, and middleware lifecycle. No later pipelined request is
parsed or dispatched. An uncommitted HTTP/1.1 response gains `Connection:
close`; an already committed response finishes if possible and the transport
then closes.

The standard grace duration is 30 seconds and is replaceable in the startup
shutdown profile. Existing ADR 0033 progress timeouts continue to apply inside
it. The grace deadline is an outer monotonic bound for uploads, downloads, and
streams that otherwise have no total-duration deadline. Ploof sends no
automatic 503 or synthetic retry delay during drain; an edge sees closed
listeners and connections while an application-selected readiness route can
observe the lifecycle state.

Grace expiry begins forced cancellation. Ploof cancels outstanding cancellable
network and file operations, closes transports, aborts response streams, and
aborts uploads that have not reached ADR 0083's explicit completion decision.
It reaps both cancellation and target CQEs before reusing an operation token,
buffer, request slot, or ring state. Every initialized middleware `after` phase
runs exactly once after the transport outcome becomes final and receives the
shutdown cause. Its final status is absent when forced cancellation occurs
before any final response was selected.

Once a multipart completion handler has selected `.commit`, neither client
disconnect nor shutdown cancellation changes ADR 0093: Ploof completes the
commit sequence or compensation. A blocking helper job also cannot be killed
inside the process; it may cooperate with cancellation, finish normally, or
prevent clean shutdown. Hard process termination has crash semantics and cannot
preserve either guarantee.

The standard forced-cancellation duration is five seconds and is independently
replaceable. `stopped` requires accepts and connections closed, all target and
cancel completions reaped, upload and sink finalization complete, initialized
`after` phases finished, workspaces returned, helper jobs quiescent and helper
threads joined, and worker rings drained and closed.

If that second deadline expires, the library returns a fixed-size
`ShutdownIncomplete` report and retains ownership of live state rather than
deinitializing it unsafely or claiming the server stopped. The report identifies
the remaining bounded operation classes and counts without request data. The
convenience runner writes that diagnostic and exits nonzero; this is explicitly
a forced process termination, not a clean shutdown. Deployment termination
budgets must exceed both configured durations.

All lifecycle commands, operation records, cancellation paths, and diagnostics
use startup-created storage. Tests cover accept and signal races, idle and
partial-head connections, each request phase, pipelined bytes, committed and
uncommitted finite responses, long streams, upload abort and post-commit
finalization, helper jobs, every CQE ordering, repeated shutdown calls, both
deadlines, and zero hot-path allocation.

Sources: [Gin graceful shutdown](https://gin-gonic.com/en/docs/server-config/graceful-restart-or-stop/),
[Express graceful shutdown](https://expressjs.com/en/advanced/healthcheck-graceful-shutdown/),
and [Node HTTP server close operations](https://nodejs.org/api/http.html#serverclosecallback).
