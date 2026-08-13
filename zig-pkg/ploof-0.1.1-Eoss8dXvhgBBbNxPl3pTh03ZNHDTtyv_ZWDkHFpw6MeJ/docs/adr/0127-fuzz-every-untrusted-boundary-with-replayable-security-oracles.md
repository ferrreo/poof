# Fuzz every untrusted boundary with replayable security oracles

Ploof treats every network- and request-controlled byte as hostile even when an
edge proxy normally precedes it. The configured proxy, Linux kernel, Zig
compiler, and application-owned or explicitly unsafe extension code are trust
roots; forwarded HTTP bytes are not. An edge proxy mitigates volumetric attacks,
while Ploof remains responsible for finite local memory, work, concurrency, and
output under every admitted or rejected input.

Zig 0.16's `std.testing.Smith` is the primary version-one fuzzing engine. Each
fuzz target accepts structured generated values or raw bytes through a small
deterministic adapter around production code. That adapter also runs as an
ordinary test over checked-in inputs. Ploof does not build a separate fuzz
parser or state machine, and no random source is hidden inside the target's
oracle.

Target families cover HTTP request lines, fields, framing, chunking, trailers,
and pipelining; PROXY protocol version 2 and forwarded-header trust; request
targets, paths, queries, percent decoding, parameters, and route selection;
gzip, JSON, URL-encoded forms, multipart boundaries and filenames; response
framing and field serialization; template compilation, interpolation escaping,
typed URLs, and browser JSON blocks; static-file confinement and upload storage
keys; and generated reactor sequences involving completions, cancellation,
timeouts, disconnects, buffer reuse, telemetry pressure, and shutdown.

For a given logical byte stream, parsing result, consumed-byte count, and final
outcome must be identical across every generated fragmentation and coalescing
pattern. Scalar reference and x86_64-v3 SIMD paths must agree. A framing error
must dispatch no request, close the connection, and make any trailing bytes
unavailable as another request. Direct, Caddy-fronted, and nginx-fronted raw
stream tests append a distinguishable second-request canary and prove it cannot
cross an ambiguous frontend/backend boundary.

Unexpected framework panic, safety trap, hang, post-start framework allocation,
pool or descriptor leak, stale pooled-data disclosure, path escape, sensitive
telemetry output, and unbounded output are failures. Test-only operation counts
bound critical parsing and framing work linearly in admitted input and configured
limits; subprocess deadlines remain the final liveness guard rather than the
complexity oracle. Encoded and decoded sizes, nesting, fields, parts, filenames,
output, route workspaces, and queue capacities are exercised immediately below,
at, and above their limits.

The security conformance suite includes RFC 9112 request smuggling and response
splitting shapes, proxy-identity spoofing, malformed PROXY frames, gzip bombs,
multipart boundary and filename attacks, traversal and symlink or mount races,
template and browser-data structure attacks, CSRF and CORS boundaries, slow and
resource-exhausting peers, upload failure and compensation, and cross-request
canaries in recycled workspaces, buffers, logs, and metrics.

Every discovered crash, hang, disagreement, or security-boundary failure is
minimized and checked into its target family's corpus with its deterministic
oracle before the fix is considered complete. The protocol-only
`SecurityCorpus` is public; scheduler and runtime corpora remain private because
reactor internals are not public API. Ordinary tests replay every corpus. Hosted
change validation runs the Debug replay suite, fuzz-driver crash and hang smoke,
and one 10,000-case Debug HTTP boundary campaign. Trusted, scheduled, and
release validation run every family in all three modes on suitable hardware.
Exact time budgets and release scheduling belong to the CI and release contract.

Fuzzing runs in Debug, ReleaseSafe, and ReleaseFast with ADR 0126's allocation
traps. Separate build steps target pure HTTP/1.1, route selection, and bounded
worker-state transitions so each family can run a native Zig campaign without
compiling an alternate implementation.

The version-one release budget covers every family enumerated by
`tools/run-fuzz-matrix.sh` in all three modes: four limited-mode processes per
target, 250,000 requested cases per process, and a 3,600-second process
deadline. This preserves one million requested cases per target and mode while
working around Zig 0.16's hardcoded single instance for limited fuzzing. The
scheduled security campaign runs two such logical campaigns, for eight
processes and two million requested cases per target. Zig may finish its active
internal batch after reaching a limit, so reported executions can exceed the
request slightly but may never fall below it. The retained manifest repeats
the exact family list, per-process budget, process count, modes, and equal
per-mode case identities; changing any value changes the reviewed gate contract
rather than silently changing runner configuration.

Public fuzz steps are fail-closed wrappers rather than direct `zig build
--fuzz` invocations. Zig 0.16.0 starts limited fuzzing after its ordinary build
state count and can save a crashing input while the build process still exits
successfully. Ploof serializes access to each logical campaign cache and gives
every shard an independent persistent cache and corpus. It divides requested
work without loss, clears only each shard's prior crash artifact, invokes the
hidden native Zig fuzz steps concurrently, terminates siblings after any
failure, and requires a successful nested status, complete fuzz reports, no
crash artifact, and no fuzz rerun error from every shard. The nested build uses
a generated patch of the installed Zig
0.16.0 build runner that turns post-fuzz `Run` error messages into failed build
steps. Generation is pinned to source SHA-256
`2791bc495d2d9f819a3cc4602578535a9ac1fd8246b77c1918dc5734c9afdf8b` and
one exact patch anchor; any version or source mismatch fails before fuzzing.
A permanent fuzz-only deliberate-crash fixture proves the wrapper returns
nonzero and preserves the replay input, while the same fixture passes in
ordinary test mode. Each public family also has an external monotonic campaign
deadline, one hour by default and configurable from one second through 24 hours
with `-Dfuzz-timeout-seconds`. A deliberate-hang fake Zig process proves expiry
returns nonzero even when graceful termination is ignored.

ThreadSanitizer separately exercises worker coordination, logging, metrics,
snapshots, and lifecycle transitions. C undefined-behavior sanitizing is added
only if C code enters the dependency tree. Version one does not add AFL,
libFuzzer, a generic reducer, or a generic static-analysis badge without
evidence that it reaches code or faults missed by Zig's native engine. Keeping
the deterministic target adapter independent of `Smith` preserves a narrow
seam for a proven future engine.

This contract costs corpus maintenance and scheduled CPU. Fast deterministic
replay stays in the normal development loop; unbounded campaigns do not.

Sources: [Zig 0.16 fuzzer](https://ziglang.org/download/0.16.0/release-notes.html#Fuzzer),
[RFC 9112](https://www.rfc-editor.org/rfc/rfc9112.html), and
[OSS-Fuzz integration guidance](https://google.github.io/oss-fuzz/advanced-topics/ideal-integration/).
