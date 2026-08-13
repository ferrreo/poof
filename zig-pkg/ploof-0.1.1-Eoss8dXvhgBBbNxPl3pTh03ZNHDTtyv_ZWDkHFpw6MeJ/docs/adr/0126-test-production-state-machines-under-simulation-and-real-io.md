# Test production state machines under simulation and real I/O

Ploof tests one production implementation at several boundaries. Pure unit and
comptime tests cover HTTP parsing and serialization, routing, headers, typed
binding, JSON, HTML templates, URL handling, compression, multipart parsing,
proxy policy, and other deterministic transformations. Boundary tables and
exact wire-output fixtures make accepted and rejected syntax explicit. Simple
scalar reference implementations serve as differential oracles for SIMD and
branchless paths. Compile-fail fixtures verify the diagnostics and rejection of
invalid route graphs, templates, schemas, and bounded configurations.

A private normalized reactor seam permits a test-only deterministic reactor to
drive the production connection, request, middleware, body, response, file,
logging, metrics, and shutdown state machines. The test reactor supplies
bounded fake sockets and files, virtual monotonic time, deterministic entropy,
and controlled completions. It is not a public portability layer, a duplicate
HTTP model, or a runtime fallback; supported production startup continues to
require ADR 0123's real io_uring contract.

Simulation varies fragmentation, coalescing, completion order, partial reads
and writes, cancellation before and after target completion, missing progress
flags, buffer recycling, pool and queue exhaustion, `ENOBUFS`, short file I/O,
filesystem failures, peer half-close and disconnect, progress deadlines,
upload commit and compensation, logger saturation and sink failure, metrics
snapshot deadlines, and both shutdown stages. A failing run reports a
replayable seed and bounded event trace. Tests use virtual time and observed
events rather than sleeps.

The M4 worker Smith consumes at most 64 actions from a replayable input and
selects only currently active submissions. Its corpus covers fragmentation,
partial sends, `ENOBUFS`, timeouts, EOF, cancellation reorder, and arbitrary
stop. Every run must finish with no queued or active operation, borrowed
buffer, live connection, or unmatched application lifecycle callback.

The M5 stream-driver Smith varies partial SENDs, exact and chunked completion,
pending and retained wakes, timeout and cancel CQE order, stale generations,
producer failure, and stop. Deterministic adversarial cases withhold timer and
cancel CQEs across repeated wakes, race full terminal and suppressed HEAD sends
against timeout, preserve the first nonterminal failure, and verify secure
response-staging clearing after success, send failure, and producer polls that
dirty the full output before returning pending or done. A near-wrap operation
test retains an identical-kind token and proves token selection skips its raw
identity. The maximum 8,192-slot wake test crosses both summary words at slots
4,095, 4,096, and 8,191.

Real Linux integration tests run the same behavioral cases through actual
io_uring, loopback TCP, child processes, and temporary filesystem roots. They
cover request fragmentation and pipelining, slow peers, half-close and abrupt
disconnect, timeouts, gzip, multipart streaming and file finalization, static
files, response streaming, resource exhaustion, startup capability errors,
and drain. Separate end-to-end suites run actual Caddy and nginx as edge
proxies and cover TLS termination, forwarding trust, PROXY protocol version 2,
streaming, compression, and uploads. Temporary roots and ephemeral ports keep
tests isolated and reproducible.

The M4 real-worker suite starts this matrix with fragmented and pipelined
requests, exact timeout responses, forced partial response sends, repeated
buffer reuse, simultaneous receive and timeout cancellation, and connection-
slot exhaustion. Kernel-specific CQE flags pass through the same normalization
code used in production. A prequeued connection burst samples process file-
descriptor count before and after every completion transfer and proves that
accepted descriptors never exceed the configured connection slots.

The M5 real-worker stream case forces a partial 256 KiB chunk on loopback,
parks the producer, resumes it through the worker eventfd and io_uring wake
completion, emits negotiated trailers, and drains shutdown to exact
quiescence. A forked variant arms the post-ready address-space-growth filter
before the request and proves the same stream completes without `mmap`,
`mremap`, or `brk`.

Every startup allocation site is exercised with indexed allocation failure,
and each failure must unwind all initialized resources. Once a test server is
ready, allocation traps remain armed for framework-owned worker, request, and
first-party logger paths. This proves the post-start allocation contract rather
than inferring it from a profiler. Long-running churn and saturation tests
verify that file descriptors, resident memory, workspaces, buffers, operations,
and queue high-water marks return or reach a stable plateau.

External plateau evidence carries the candidate-bound version-one manifest from
`release/gates.json`. It records the exact measurement interval and sample
count, zero post-start framework allocations and descriptor delta, and explicit
stable RSS, workspace, and operation declarations. Release verification checks
those values rather than treating the presence of a tar or profiler output as a
plateau result.

At the M4 worker boundary, child-process seccomp filters inject `ENOMEM` into
ring setup, SQ/CQ mapping, SQE mapping, provided-buffer descriptor mapping, and
buffer registration. Each case requires a closed backend and an unchanged
open-descriptor count. After readiness, another filter terminates the child on
`mmap`, `mremap`, or `brk`; repeated keep-alive requests and clean shutdown must
complete while that filter remains armed.

Correctness suites run in Debug, ReleaseSafe, and ReleaseFast modes. ReleaseFast
proves behavior with safety checks removed and also belongs to the benchmark
contract; it does not substitute for Debug or ReleaseSafe checks. Source
coverage is retained as a regression signal, but no percentage is treated as
proof. Every reachable transition, boundary, invariant, error
mapping, resource-exhaustion result, and injected failure edge in critical
parser, reactor, framing, multipart, template, and lifecycle code must have an
explicit test.

Gin- and Express-familiar application workflows have conformance fixtures for
Ploof's public defaults and APIs. Deliberate Zig, safety, or performance
differences are recorded in those fixtures rather than silently copying either
framework. Simulation and real-I/O suites share behavioral cases so the test
reactor cannot become an independently correct but irrelevant model.

This costs test-only code and CI time. Keeping one narrow private reactor seam,
one set of production state machines, and shared cases limits that cost and
detects simulator drift.

Sources: [TigerBeetle deterministic simulation][tiger-simulation],
[TigerBeetle VOPR](https://docs.tigerbeetle.com/single-page/), and
[Zig 0.16.0 release notes](https://ziglang.org/download/0.16.0/release-notes.html).

[tiger-simulation]:
  https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/ARCHITECTURE.md
