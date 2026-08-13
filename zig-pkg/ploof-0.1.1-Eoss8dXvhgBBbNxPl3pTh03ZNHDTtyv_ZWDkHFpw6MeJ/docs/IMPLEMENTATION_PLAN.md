# Ploof implementation plan

This plan orders work by dependency and risk rather than ADR number. Each
milestone ends in a runnable vertical slice with explicit failure tests. Work
does not move past a milestone while its exit gate is failing.

ADR 0015, ADR 0022, and ADR 0023 are superseded. Only ADR 0043's four-phase
middleware contract is implemented.

## Rules for every milestone

- Keep production dependencies empty. Ploof links neither libc nor liburing.
- Build, test, and fuzz Debug, ReleaseSafe, and ReleaseFast. Benchmark every
  case in both release modes; ReleaseSafe remains the production result.
- Use bounded startup-created storage. Assert zero framework allocations after
  readiness as soon as a runtime path exists.
- Exercise production state machines through deterministic and real I/O paths;
  never create a second test implementation.
- Add boundary, failure, allocation, fuzz, and security-corpus coverage with
  the code that creates the boundary.
- Begin with scalar, direct code. SIMD, branchless transforms, batching, and
  other complexity ship only after differential tests and sigbench evidence.
- Keep public declarations in the curated root modules. Internal layouts,
  reactor details, generated code, and benchmark hooks stay private.

## Milestones

### M0 - Package and toolchain skeleton

ADRs: 0005–0006, 0014, 0129–0130.

Exit: a clean path-dependent package fixture imports only `ploof` and
`ploof_testing`; `ploof-assets` is a lazy host artifact; Debug, ReleaseSafe, and
ReleaseFast build; wrong Zig, OS, architecture, or CPU fails clearly; the
canonical ELF has no libc, liburing, interpreter, dynamic dependency, or
unresolved C symbol.

### M1 - Kernel and reactor feasibility spine

ADRs: 0001–0002 and the base capabilities from 0123.

Exit: a libc-free program creates every required ring flag, checks feature and
opcode manifests, registers a non-incremental provided-buffer ring, and
actively proves NOP, multishot accept and receive, send, timeout, and
cancellation. Every failure returns bounded typed startup detail.

### M2 - Pure HTTP/1.1 protocol core

ADRs: 0003–0004, 0034–0042, 0044–0050.

Exit: fragmented and contiguous requests produce identical results. Exact
response bytes cover fixed and chunked bodies, HEAD and bodyless statuses,
trailers, duplicate fields, limits, malformed input, and request-smuggling
canaries without opening a socket. Response media types use one typed parser
and the exact JSON, HTML, text, and octet-stream defaults.

### M3 - Closed application graph

ADRs: 0009–0017 and 0043.

Exit: a synthetic GET flows through parsing, route selection, four middleware
phases, a typed handler or error mapper, and serialization. Parameters, slash
redirects, GET/HEAD, OPTIONS, 405/501, conflicts, application state, and
compile failures are covered.

### M4 - Bounded integrated server

ADRs: 0007–0008, 0032–0033, 0072–0073, and the foundation of 0126.

Exit: the same `/ping` application passes the private deterministic reactor
and real loopback io_uring. Fragmentation, pipelining, timeouts, partial sends,
cancellation, slot exhaustion, buffer reuse, startup failure, and zero
post-ready allocation pass. `ploof_testing` exposes only a high-level client.

### M5 - Body and streaming transport

ADRs: 0016, 0018–0019, 0024, integrated 0040–0042, and 0069–0071.

Exit: raw and text POST routes handle fixed and chunked identity or gzip
bodies, request trailers, `100 Continue`, finite and streaming responses,
backpressure, encoded and decoded limits, gzip-pool exhaustion, exact-length
failure, and workspace rejection.

### M6 - Query, forms, and JSON

ADRs: 0039, 0051–0068, 0074, and 0131.

Exit: one route accepts explicit JSON or form alternatives plus query input and
returns bounded JSON. Tests cover schemas, duplicate names, memory limits,
codecs, cardinality, defaults, UTF-8, percent decoding, unknown fields,
dynamic JSON, and absence of parser fallback.

### M7 - Proxy identity and CORS

ADRs: the trust boundary from 0003, 0013, 0027–0031, and 0038.

Exit: direct, trusted, and spoofed peers produce distinct typed provenance.
PROXY v2, one forwarding family, effective host, absolute form, route-derived
preflight, wildcard CORS, credentials, and `null` origins pass direct, Caddy,
and nginx tests.

### M8 - Multipart schema and parser

ADRs: 0020–0021, 0075–0081, 0084–0088, 0090–0091.

Exit: fragmented multipart drives typed fields and a synchronous discard sink.
Tests cover boundaries, headers, filenames, empty markers, unknown and nested
parts, cardinality, media claims, UTF-8, the 64/1,024-byte delimiter-padding and
16/64 disposition-parameter bounds, case-insensitive parameter duplication,
aborts, and configured-size workspace memory.

### M9 - Asynchronous upload transactions and `FileSink`

ADRs: 0082–0083, 0089, 0092–0097, and file additions to 0123.

Exit: real filesystem uploads commit in declared order and respond only after
finalization. Short and out-of-order writes, sink-window backpressure,
disconnect, commit failure, reverse compensation, `openat2` confinement,
staging modes, no-replace, and durability modes pass.

### M10 - CSRF completion

ADRs: 0025–0026 integrated with 0024, 0028, and 0081.

Exit: cookie-authenticated routes accept valid header, form, and multipart
tokens and reject duplicates, cross-origin input, invalid keyrings or bindings,
late multipart tokens, and invalid `Expect` requests before upload bytes.

### M11 - Typed HTML and URL safety

ADRs: 0098 and 0100–0119.

Exit: a consumer renders documents, layouts, partials, control flow, helpers,
typed URLs, trusted HTML, static SVG, and browser JSON into bounded chunks.
Compile failures cover forbidden contexts; structure, XSS, exhaustion, helper,
gzip, and allocation tests pass.

### M12 - Embedded assets and live static files

ADRs: 0099, 0120–0122, and the asset surface from 0129.

Exit: a clean consumer invokes `ploof-assets` and gets byte-identical generated
source. Asset GET/HEAD, gzip, ETags, CDN origin, and routing pass. Static files
cover traversal, symlinks, mounts, indexes, validators, ranges, mutation, short
reads, cancellation, and pool exhaustion. Filename media types use the bounded
static extension table from ADR 0050 with octet-stream fallback.

### M13 - Observability and irreversible lifecycle

ADRs: 0124–0125 and completion of 0008.

Exit: mixed JSON, template, upload, and static load exports complete bounded
metrics and saturates zero-allocation logging without blocking or leaking
canaries. Drain covers every phase, helper job, logger flush, repeated signal,
forced cancellation, reordered CQEs, clean stop, and `ShutdownIncomplete`.

### M14 - Release closure

ADRs: 0126–0131.

Exit: shared deterministic and real suites, security corpus, Smith campaigns,
ThreadSanitizer, allocation sweeps, resource plateaus, matched ReleaseSafe and
ReleaseFast sigbench suites, ReleaseSafe regression gates, proxy and kernel
matrices, two-machine results, 24-hour soak, archive consumers, SBOM,
provenance, hashes, documentation, migrations, and security policy pass on the
exact tag candidate.

## Cross-milestone prerequisites

- M1 builds capability accumulation once. `FileSink` and static-file opcodes and
  active probes extend it in M9 and M12; they do not create another probe.
- M4 starts the workspace planner, operation inventory, metrics cells, and
  shutdown accounting. Later features extend those closed inventories without
  adding heap fallback or runtime registries.
- M2 injects an already formatted `Date` into the pure response serializer. M4
  supplies it from the once-per-second worker cache required by ADR 0048.
- M2 validates dynamic protocol values and provides comptime media-type and
  static-identity constructors. M3 owns compile-failure fixtures for static
  response combinations, reserved fields, and route head-size proofs once the
  typed `Response` and closed route graph exist.
- M2 validates and decodes absolute-form syntax while retaining its authority as
  unverified. M7 compares its normalized scheme and authority with the listener
  forwarding profile before dispatch, completing ADR 0038's trust check.
- Full CSRF waits for form and multipart delivery. `100 Continue` begins in M5
  and gains multipart and CSRF cases when those facilities exist.
- `ploof-assets` is the public build path: enumerated inputs produce one
  generated module. Embedding may be used inside that generated code.
- Sigbench 0.0.5 is pinned lazily by tag URL and content hash. Explicit
  benchmark activation preserves normal builds' no-fetch dependency boundary.
- Kernel images, Intel and AMD runners, Caddy and nginx fixtures, performance
  hosts, signing keys, and provenance configuration are external M14 inputs,
  not source constants.

## Current work

M0 through M13 are source-complete. Their deterministic state-machine tests,
real io_uring integrations, allocation-denial checks, security corpora,
Debug/ReleaseSafe/ReleaseFast fuzz families, matched Sigbench cases, proxy
topologies, and ThreadSanitizer coverage are rooted in the build graph. The
repository also contains M14's bounded first-party HTTP load driver,
fail-closed external-evidence contracts and validator, deterministic release
notes and archive tooling, clean archive-consumer verification, release
workflows, and operator documentation.

M14 is active. Before freezing a candidate, the complete graph, every
release-mode fuzz step, matched ReleaseSafe/ReleaseFast benchmarks,
package/archive consumers, structural gates, and independent security,
correctness, TigerStyle, Zig, and complexity reviews must pass again on one
immutable revision. Results from a changing checkout are intermediate evidence,
not a release claim.

Several M14 exit inputs cannot be manufactured by this checkout. Release
evidence must come from the minimum-version kernel matrix on Intel and AMD,
two distinct physical performance machines, the full configured fuzz budgets,
resource-plateau workloads, an exact 86,400-second soak, pinned Caddy and nginx
topologies, a trusted signed annotated tag, and the protected provenance and
publication environment. The release tooling rejects missing, shortened,
mixed-revision, duplicate-machine, stale, skipped, or mismatched evidence. M14
and version 0.1.0 remain open until those exact-candidate records pass; local
success alone is not production-release evidence.
