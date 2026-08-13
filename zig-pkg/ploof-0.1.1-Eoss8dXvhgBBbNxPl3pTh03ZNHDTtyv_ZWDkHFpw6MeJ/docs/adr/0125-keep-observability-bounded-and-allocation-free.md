# Keep observability bounded and allocation-free

Core runtime metrics are enabled in every supported production build. A
test-only no-metrics oracle may compile them out solely to measure their cost.
Each worker exclusively updates cache-line-isolated, non-atomic cells indexed
by comptime route IDs and closed runtime enums. There is no dynamic registry,
hash lookup, arbitrary label map, or shared atomic increment on the request
path.

Per-route cells cover admitted, active, and completed requests; normalized
method; status class; closed application and transport outcomes; wire and
decoded bytes; and a fixed latency histogram. Runtime cells cover connections,
parser and framing failures, progress timeouts, pool capacity and high-water
marks, overload rejection, gzip decisions, multipart and sink outcomes, static
files, io_uring failures, cancellation, CQ and SQ invariants, lifecycle state,
and dropped telemetry. Timing reuses monotonic samples already maintained by
the worker for deadlines rather than making one clock syscall per metric.

Metric dimensions can contain only compile-time route patterns and finite
method, status-class, listener, outcome, error-class, or workspace-class values.
Raw or decoded paths, parameters, query strings, hosts, addresses, request IDs,
headers, bodies, user agents, filenames, storage keys, identity values, and
arbitrary error text can never become metric labels. The generated memory and
series count are finite and reported during startup.

Only one metrics snapshot may be active. A management request asks each worker
to copy cumulative cells into its preallocated epoch buffer in bounded work at
safe event-loop points. Merging and formatting occur off request workers. A
snapshot that cannot complete within its finite management deadline fails; it
never stalls serving or presents a partial epoch as complete.

Ploof exposes the typed `MetricsSnapshot` and a first-party OpenMetrics 1.0
formatter. An application must explicitly register its metrics route, which is
an ordinary route subject to its chosen listener, proxy restriction,
authentication, and middleware. No `/metrics` path is reserved automatically.
The formatter has a checked output bound, uses startup-pooled response chunks,
and permits one in-flight exposition; a concurrent scrape or failed snapshot
receives the preallocated 503 response.

The route runs head and body middleware before it claims the one server-owned
snapshot-helper slot, but emits no response-head bytes until the helper returns
a complete snapshot or the route selects its preallocated 503. Its absolute
deadline is a checked addition of the worker's latest monotonic sample and the
configured snapshot timeout; overflow selects the 503 without another clock
syscall. The request retains an immutable generation ticket, and successful
formatted bytes remain borrowed from the helper until transport completion.
Disconnect, forced shutdown, and other aborts cancel that generation; the slot
is reusable only after helper acknowledgement, while late wakes fail closed.

Ploof also provides allocation-free liveness and readiness handlers without
choosing their paths. Liveness returns 204 when the handler executes. Readiness
returns 204 only in ADR 0124's `ready` lifecycle state and otherwise returns
503. Application dependency checks remain ordinary typed handlers rather than
an implicit global registry.

First-party access logging is an explicitly installed comptime middleware. Its
`after` phase constructs one fixed-size `AccessEvent` and enqueues it into the
owning worker's bounded single-producer/single-consumer ring. A logger thread
drains those rings and writes structured NDJSON to the configured first-party
file-descriptor sink. That sink must be a writable `O_NONBLOCK` pipe or socket;
regular files are rejected because `O_NONBLOCK` does not bound their writes.
Disabled logging contributes no request-slot storage, runtime branch, logger
thread, or queue.

The complete first-party logging path performs zero allocations after startup,
including the logger thread. Event rings, formatter state, maximum NDJSON
record, batch buffers, escaping scratch space, and sink state are created up
front. Every enabled field has a comptime maximum that participates in the
record and output bounds; an impossible configuration fails before serving
rather than growing, truncating, or allocating. Each sink write has a fixed
syscall-attempt bound. A zero-byte `EAGAIN` or exhausted `EINTR` drops that
record but preserves the sink; a partial or permanent failure retires the sink
so later records cannot follow a truncated NDJSON record. A custom application
sink is responsible for preserving the same contract internally and is outside
Ploof's allocation guarantee.

Before logger startup succeeds, its thread blocks `SIGPIPE` using the Linux
signal-mask syscall and reports a typed startup failure if that cannot be
installed. A disconnected pipe or stream socket therefore returns `EPIPE` to
the bounded sink path instead of terminating the process. Mask failure joins
the helper before returning, so failed server startup retains no logger-owned
storage. The generated signal remains pending only for that blocked logger
thread and is discarded when the thread exits.

The default access event contains normalized method, static route identity or
the finite unmatched value, exact response status when one exists, closed
outcomes, duration, and wire byte counts. Raw targets and paths, parameters,
queries, headers, cookies, bodies, host, peer or effective client addresses,
user agent, referrer, filenames, request IDs, user identities, and error text
require an explicit bounded application logging policy. Request-controlled
bytes are never inserted into the default formatter.

Status is absent when a disconnect, timeout, cancellation, or shutdown aborts
an admitted request before any final response is selected. An interim 100 and
default or synthetic status never fill that absence.

A full event ring or failed sink never blocks a worker, allocates, or rejects a
request. It drops the routine event and increments an exact per-worker loss
counter. The access logger is therefore observability, not an audit log;
security or compliance events requiring durable delivery need an application-
owned transactional design. Shutdown attempts a bounded drain and reports
both queued and logger-owned in-flight events, plus log loss, without weakening
ADR 0124's server-state safety.

Version one has no OpenTelemetry dependency, SDK, exporter, baggage store, or
generic tracing abstraction. Typed middleware already receives static route
identity and the immutable final application and transport outcome needed by a
W3C or OpenTelemetry adapter. Such an adapter must export off worker threads.

Zig panics and safety traps remain process-fatal. Ploof's closed application
error mapper handles typed failures, but the framework does not claim it can
unwind arbitrary Zig state and continue through a Gin-style recovery
middleware.

Verification proves metric cardinality cannot depend on request bytes,
snapshots contain complete epochs, all queue and sink failure paths remain
bounded, sensitive canaries never enter default output, and both worker and
logger allocation traps remain armed after startup. Sigbench compares the core
metrics oracle, snapshots, enabled logging, saturated logging, one and many
routes, finite and streaming bodies, and every feature-specific metric family.

Sources: [Gin logging](https://gin-gonic.com/en/docs/logging/),
[Express production logging](https://expressjs.com/en/advanced/best-practice-performance/),
[OpenMetrics exposition](https://prometheus.io/docs/instrumenting/exposition_formats/),
and [OpenTelemetry HTTP semantic conventions](https://opentelemetry.io/docs/specs/semconv/http/).
