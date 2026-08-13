# Gate ReleaseSafe performance with sigbench

Ploof pins the `ferrreo/sigbench` 0.0.5 tag archive and exact content hash as a
lazy benchmark-only Zig dependency. `-Dbenchmarks=true` activates it; normal
builds neither fetch nor compile it. It does not enter Ploof's public module or
production binary, and one thin benchmark runner isolates API changes.
Sigbench owns sampling, confidence intervals, baseline comparison, reports,
and gates; Ploof does not fork its statistical engine.

Performance evidence has three distinct tiers. In-process cases isolate the
request parser and framer, chunk decoder, router, field operations, target and
form decoding, JSON, HTML templates, gzip, multipart scanning, proxy parsing,
response serialization, pools, CQE dispatch, metrics, and logging. Real-runtime
cases drive the production io_uring server over loopback in isolated processes.
Deployment cases use separate physical client and server machines and exercise
both direct HTTP/1.1 and the supported Caddy and nginx edge topologies. Results
from one tier never masquerade as another.

The first in-process group measures request-head decoding, closed route
selection, fixed identity body receipt, a 4 KiB no-trailer chunked body, a
fragmented multi-chunk body with declared trailers, and secure clearing of the
exact 9,736-byte pooled chunked state followed by release and reacquisition.
Chunked cases construct fresh state per timed iteration, preserve an exact
pipeline tail, and validate decoded zero-copy spans, counters, and trailers.
Fixture and declaration preparation stays outside the timed region. Body
throughput counts decoded payload bytes; the clear case counts state bytes
overwritten. These cases import private modules only into the benchmark
executable and allocate nothing in timed routines.

The in-process group also includes full-head and two-fragment deterministic-
reactor lifecycle cases. Each drives the production connection driver through
head decoding, routing, response send completion, cancellation retirement,
and one-shot keepalive rearm. These are allocation-free runtime state-machine
measurements, not io_uring, loopback, or deployment transport evidence.

Ploof's bounded in-tree load driver produces validated requests, checks exact
statuses and response identities, records a finite latency histogram, and
reports any transport or application failure. It varies representative payload
sizes, route-graph sizes, connection reuse and churn, pipeline depth, worker
count, concurrency, offered load, and overload. Anchor workloads cover minimal
fixed responses, typed JSON, HTML templates, identity and gzip bodies,
multipart discard and file sinks, embedded and live static files, finite and
streaming responses, and trusted proxy metadata. Focused cases cover every
other feature without taking the full Cartesian product.

Closed-loop cases find peak capacity. Constant-rate cases schedule requests
independently of prior completions and measure latency from scheduled send time,
so server queueing cannot disappear through coordinated omission. The client
machine and load driver must demonstrate at least twice the selected offered
load without the server before a deployment result is valid. Client and server
work run on disjoint pinned physical cores with fixed NUMA, IRQ, frequency, and
power policy recorded in the manifest.

Reports include requests and bytes per second; p50, p95, p99, and p99.9 request
latency at fixed offered loads; the saturation knee and overload outcomes; idle
CPU; total worker and helper CPU time; cycles, instructions, branches and branch
misses, cache misses, syscalls, context switches, and wakeups per request; RSS,
Proportional Set Size, peak memory, and memory per configured connection and
workspace; startup time and allocations; and post-start allocations. Separate
build cases measure compile time, compiler peak RSS, binary size, and generated
code growth as routes, middleware, templates, and embedded assets increase.

Feature-tax pairs measure the standard metrics build against the test-only
no-metrics oracle, and measure access logging disabled, enabled, and saturated;
gzip decisions and pool pressure; proxy processing; middleware depth; and each
streaming path. Benchmark-only counters may explain state transitions, SQEs,
CQEs, buffer reuse, and batches, but headline timing uses the production build
without those extra probes. External profiling is diagnostic rather than part
of the request API.

Every benchmark case runs in ReleaseSafe and ReleaseFast with the same workload,
configuration, and validity checks. ReleaseSafe is the supported production,
headline, and regression build. ReleaseFast is a secondary diagnostic ceiling
that quantifies safety-check cost. Ploof optimizes a material ReleaseSafe gap
rather than recommending that users disable safety. Debug builds remain
correctness tools, not speed comparisons.

`zig build -Dbenchmarks=true bench` and `bench-release-safe` run the ReleaseSafe
headline. `bench-release-fast` runs the paired diagnostic from the same case
definition. Sigbench command-line filters, list, quick, baseline, and gate
arguments pass through after `--`. Release jobs invoke regression gates only
through `bench-release-safe`; ReleaseFast comparisons remain diagnostic and do
not control the release decision.

Real-filesystem cases use sigbench 0.0.5's `iterBatchWithTeardown`. Per-batch
setup creates a clean destination, only the production upload routine is timed,
and teardown validates and removes its result outside the measured region.
Teardown runs once after every successful setup even when measurement start or
end fails. The callback contract is intentionally infallible; a routine or
teardown panic terminates the benchmark instead of pretending cleanup succeeded.

Every proposed SIMD, branchless, prefetch, batching, layout, or syscall-path
optimization begins with the scalar or simpler implementation. It ships only
when differential tests prove equivalent behavior and sigbench shows a
repeatable benefit on representative boundary and steady-state inputs without
a material tail-latency or memory regression. Assembly and Linux perf evidence
explain the result; a single best run does not.

Hot loops whose instruction bytes are stable but whose performance changes
with unrelated comptime code layout may request an explicit cache-line-aligned
entry. The flat query/form parser uses 64-byte entry alignment for this reason:
old and candidate ReleaseSafe disassembly differed only in relocated calls and
constants, while the unaligned candidate moved the entry by half a cache line.
Two aligned ReleaseSafe query runs measured 182.186 ns and 182.351 ns against
the preserved 186.637 ns baseline. A later six-case matched ReleaseSafe run
measured 187.291 ns, within the gate at +0.35%. Alignment is a code-layout
contract, not permission to compare optimization modes or select a best run.

Regression jobs build the merge base and candidate, then measure them beside
one another on the same dedicated, pinned x86_64-v3 host. The initial sigbench
noise threshold is two percent at 95 percent confidence. Repeated unchanged-
build comparisons calibrate each case; a noisier threshold can increase only
with recorded evidence, not merely to pass a change. A statistically
significant regression blocks when its confidence interval lies beyond the
calibrated threshold.

Incorrect output, an unexpected error, a post-start allocation, a resource
leak, or violation of an explicit absolute CPU, memory, startup, compile, or
binary-size budget is a hard failure independent of statistical timing. Initial
measurements establish honest per-case absolute budgets before they become
release gates. A change to a baseline, budget, or threshold carries its own
evidence and cannot silently erase a regression.

Every run archives its benchmark manifest, exact binaries and configurations,
raw samples, histograms, and reports. The manifest includes both source
revisions, compiler and sigbench identities, CPU model and microcode, kernel,
proxy and comparison-framework versions, topology and affinity, and CPU power
policy. A hardware, kernel, compiler, or topology change starts a new baseline
series rather than comparing incompatible numbers.

The outer external-evidence manifest makes the release tool enforce the subset
needed before it trusts those retained files. Candidate and non-identical
baseline revisions are mandatory for comparison gates. ReleaseSafe and
ReleaseFast case arrays must be nonempty and byte-for-byte equal, topology and
workload arrays must equal the gate profile, and Sigbench identity must equal
the pinned version, source SHA-256, and Zig package hash. Runtime and deployment
profiles also identify version one of the in-tree load driver, a deterministic
digest over its seven candidate source blobs, and the path and SHA-256 of the
retained executable actually measured. Two-machine
profiles name physical client and server machine-ID hashes and reject equality;
the recorder runner's kernel, CPU, architecture, and identity must match one of
those hosts.

Published Gin and Express cases use the same validated wire result, enabled
features, reverse-proxy topology, and total server-core budget. Gin uses release
mode. Express uses `NODE_ENV=production` and an equal worker count. These
replacement-target comparisons are reproducible reports, not CI dependencies
whose upstream version or runtime noise can block Ploof changes.

Sigbench is a statistical microbenchmarking library, not an HTTP load generator.
Its current Linux performance-counter and multi-metric HTTP reporting surface
does not cover every required measurement. Ploof adds the load driver locally;
a reusable missing measurement belongs upstream in sigbench, while Ploof may
retain bounded secondary histogram and diagnostic artifacts until that support
exists. Finite-response gzip therefore emits one deterministic companion
`metrics.json` beside each selected Sigbench output directory; ReleaseSafe and
ReleaseFast must contain the same case identities and derived wire metrics.
Response streaming emits the same companion shape under `response-stream/`.
Its paired eight-case group measures exact production and fixed framing,
unknown-length chunk framing, eventfd wake-to-poll resume, a steady-state
deterministic connection lifecycle, sparse dispatch at 64, 1,024, and 8,192
request slots, and one dense 64-ready batch. The companion records wire bytes,
producer polls, send and control completions, eventfd activity, configured and
ready slots, and callback dispatches. ReleaseSafe and ReleaseFast companions
are byte-identical with SHA-256:

```text
9485699564cff436cd11af8daaaca71dd7065a223a091bae21d2311af284c0ed
```

The settled ReleaseSafe/ReleaseFast medians in nanoseconds are exact framing
162.442/134.451, unknown chunk framing 202.963/161.089, eventfd wake-to-poll
146.812/144.171, deterministic driver 5,895.283/5,762.092, sparse dispatch at
64 slots 139.135/136.444, 1,024 slots 139.014/137.468, 8,192 slots
143.064/140.890, and dense 64-ready dispatch 1,567.175/1,547.912. Sparse
8,192-slot dispatch is only 2.82 percent/3.26 percent above 64 slots, which is
the evidence for the two-level set-bit inventory rather than a capacity scan.

Raw samples, estimates, reports, and metrics remain under
`zig-out/sigbench/{release-safe,release-fast}/response-stream/`.
It never labels an unavailable counter as a measured value.

M6 adds two paired in-process groups. The six micro anchors measure strict flat
query and URL-encoded form parse-plus-bind, typed and dynamic JSON decode, typed
JSON encode, and the Endpoint materializer with a nonzero-index selected JSON
alternative. Their settled ReleaseSafe/ReleaseFast medians in nanoseconds are
query 183.067/168.720, form 131.968/124.341, typed JSON decode
1,227.718/1,002.713, dynamic JSON decode 1,136.532/896.285, JSON encode
202.079/214.269, and Endpoint materialization 919.752/692.342.

The four production-pipeline companions cover the previously separate costs.
One case fragments the request head and retained escaped JSON body, then times
global query admission, route planning, suffix-media selection, retained-body
copy, and typed materialization. One repeats that path at the exact 1,000-query-
segment standard limit. Two worker-backed Endpoint cases encode an exact-capacity
JSON response carrying a field 256 bytes beyond the default 72 KiB staging,
serialize identity or gzip, and commit the external body-workspace source. Every
case black-boxes runtime inputs and validates all typed
values or exact identity/gzip wire accounting after timing. Their
ReleaseSafe/ReleaseFast medians in nanoseconds are fragmented escaped input
2,141.694/1,898.422, standard-limit input 42,010.009/38,227.254, external
identity 41,120.100/38,199.729, and external gzip
379,765.131/329,774.038. ReleaseFast remains a diagnostic rather than an
assumption that every case becomes faster.

The aggregate SHA-256 over the sorted per-case `sample.json` and
`estimates.json` checksums for both modes is:

```text
9e999e56b299f106bfb9d68ce333c0b9fc2a947494a1bb9128de6796810b2985
```

Raw M6 artifacts remain under
`zig-out/sigbench/{release-safe,release-fast}/m6-input-json/`.

The companion `m6-input-json-pipeline` group's aggregate SHA-256, calculated by
hashing the path-sorted per-case `sample.json` and `estimates.json` checksum
stream for both modes, is:

```text
4eddf702ffa8f4866cda5fbe1205cdb3b602dc6ba91072b7afc30b1a6e6bf24c
```

Its raw artifacts remain under
`zig-out/sigbench/{release-safe,release-fast}/m6-input-json-pipeline/`.

M7 retains nine paired proxy-identity and CORS micro cases. Setup work that
belongs at listener or request-head admission time remains outside each timed
loop. Every loop validates a stable semantic fingerprint after timing. Their
settled ReleaseSafe/ReleaseFast medians in nanoseconds are:

- `proxy-v2-contiguous`: 86.502/94.226.
- `proxy-v2-byte-fragmented`: 334.335/335.030.
- `forwarded-trusted`: 224.598/149.104.
- `forwarded-untrusted`: 94.396/49.624.
- `x-forwarded-trusted`: 175.607/132.561.
- `x-forwarded-untrusted`: 101.585/54.159.
- `absolute-effective-origin`: 478.748/382.587.
- `cors-actual-exact`: 185.108/124.440.
- `cors-preflight-exact`: 217.502/154.885.

The `m7-cors-application` group adds nine full-Application feature-tax cases.
Request-head parsing and fixture construction remain outside timing, while route
selection, CORS policy, handler execution, final serialization, and completion
remain inside. Gzip cases bind the same finite-response workspace used by the
production runtime. Every case checks a hard-coded fingerprint over status and
exact serialized bytes. Their ReleaseSafe/ReleaseFast medians in nanoseconds
are:

- `disabled-non-cors`: 109.050/95.246.
- `enabled-non-cors`: 180.348/131.275.
- `allowed-actual`: 464.328/339.106.
- `allowed-preflight`: 636.123/468.349.
- `denied-preflight`: 331.658/252.379.
- `max-64-origins-actual`: 3,247.478/2,601.876.
- `max-64-origins-headers-preflight`: 10,576.826/10,005.024.
- `gzip-disabled-origin`: 73,973.271/64,305.197.
- `gzip-enabled-actual`: 74,384.932/64,723.695.

Enabling CORS on a request without `Origin` adds 65.4 percent/37.8 percent in
this full-Application pair. Adding the allowed CORS decision to the gzip path
adds 0.56 percent/0.65 percent. These are in-process feature taxes, not socket
throughput claims.

The `m7-proxy-runtime` group adds twelve production-path scaling and boundary
cases. Scalar and SIMD PROXY feeds use identical full frames, strict prefixes,
and first-, middle-, and last-byte signature mismatches. Differential tests
compare exact state and consumed counts at lengths 0 through 12, every two-part
split of TCP4 and TCP6 plus mismatches, and every byte of a fragmented TCP4
frame. ReleaseSafe disassembly confirms one 12-byte `vpcmpeqb` and mask test
before the shared decoder loop. The ReleaseSafe/ReleaseFast medians in
nanoseconds are:

- `proxy-signature-common-scalar`: 158.000/149.036.
- `proxy-signature-common-simd`: 90.586/86.290.
- `proxy-signature-boundaries-scalar`: 570.380/546.784.
- `proxy-signature-boundaries-simd`: 515.220/482.295.
- `proxy-v2-common-short`: 88.022/88.973.
- `proxy-v2-max-opaque`: 89.685/93.755.
- `forwarding-fields-1`: 166.740/107.794.
- `forwarding-fields-128`: 222.935/137.245.
- `forwarding-fields-1024`: 624.020/336.216.
- `worker-loop-dispatch-1`: 3.083/3.086.
- `worker-loop-dispatch-128`: 3.092/3.090.
- `worker-loop-dispatch-8192`: 3.090/3.091.

SIMD lowers the common-feed median by 42.7 percent/42.1 percent and the boundary
median by 9.7 percent/11.8 percent, satisfying the differential-evidence rule.
The maximum opaque case declares the full 65,535-byte payload and demonstrates
the bulk skip. Forwarding scaling counts exactly 1, 128, and 1,024 physical
fields. The worker cases isolate the `Loop.step` dispatch contract with
non-inlined fake callbacks and prove that it never calls the scanning
`cleanupStatus`. Their stable medians support cardinality-independent generic
dispatch only; they are not end-to-end production Worker scaling evidence.

The aggregate SHA-256 values over each path-sorted per-case `sample.json` and
`estimates.json` checksum stream for both modes are:

```text
m7-proxy-cors        50a01ed9b37cf1a16e12f15f7d9f0ed487b9b2c64432518eb312f67f9732f27b
m7-cors-application  a29f8a1649e71160e143b79e4eea3260e408ca75bc7c3cfeacd380bfb91df81b
m7-proxy-runtime     19b0d0d643b4731821f99fa4f8dcea0b81cbd737b6492bae6ceb849b3494bcac
all M7 groups        6d0dea5bd0a343822d5dc03a36263e67c5beb4c00bd08361b94fd537ecb0dc77
```

Raw M7 artifacts remain under these paired mode directories:

- `zig-out/sigbench/{release-safe,release-fast}/m7-proxy-cors/`.
- `zig-out/sigbench/{release-safe,release-fast}/m7-cors-application/`.
- `zig-out/sigbench/{release-safe,release-fast}/m7-proxy-runtime/`.

M8 moves custom timing to sigbench 0.0.5's scoped measurement API. Each driver
callback creates its harness, starts any required helper threads, opens a
connection, and performs one validating prime before `MeasurementScope.start`.
The measured loop includes the complete request lifecycle and its semantic and
resource-recovery oracles. Teardown follows `MeasurementScope.stop`. Rejection
cases prime one closed connection before timing, then measure a fresh connection
per iteration. The two-slot decoder case likewise primes one complete pair before
timing.

The pure parser pair uses the same large body for both feed shapes, creates a
fresh parser each iteration, and obscures the fixture behind a runtime slice.
It therefore changes only contiguous versus 64-byte feeds. Driver success
oracles require exact typed values and response bytes, zero retained multipart
body bytes, and full pool recovery. The large gzip cases require observed queue
backpressure; the large gzip-multipart case requires more than one decoded
output dispatch. Its stored deflate blocks exercise request decoding and
multipart delivery, not compressor performance.

All 15 wall-time cases retain 100 samples in both modes. Their audited
ReleaseSafe/ReleaseFast medians in nanoseconds are:

- gzip `fixed-contiguous`: 197,590.444/198,667.879.
- gzip `fixed-fragmented`: 197,636.265/198,534.480.
- gzip `chunked-trailers`: 197,972.412/198,059.038.
- gzip `large-fixed-queue-pressure`: 366,928.839/409,350.613.
- gzip `large-chunked-backpressure`: 406,653.581/358,589.452.
- gzip `multipart-fixed-stream`: 206,331.710/202,006.540.
- gzip `multipart-multi-mailbox`: 211,239.633/206,963.083.
- gzip `two-slot-multistream-contention`: 3,570.261/4,350.555.
- gzip `malformed-rejection`: 388,909.263/385,511.994.
- gzip `decoded-limit-rejection`: 386,264.804/386,834.198.
- parser `valid-large-contiguous`: 888.141/857.774.
- parser `valid-large-fragmented-64`: 989.858/967.212.
- identity `fixed-contiguous`: 193,025.014/192,696.706.
- identity `chunked-contiguous`: 193,256.965/192,829.149.
- identity `fixed-large-fragmented`: 193,337.098/192,906.167.

Pinned serialized TSC is valid for the five single-threaded multipart cases.
Pinning before a gzip case would also pin newly created decoder threads to the
same CPU, changing the workload, so threaded cases do not retain that control.
The audited ReleaseSafe/ReleaseFast medians in cycles are:

- parser `valid-large-contiguous`: 3,892.522/3,710.224.
- parser `valid-large-fragmented-64`: 4,327.672/4,093.003.
- identity `fixed-contiguous`: 849,635.308/849,059.579.
- identity `chunked-contiguous`: 850,154.674/850,025.719.
- identity `fixed-large-fragmented`: 850,113.247/849,870.561.

The ten threaded gzip cases instead retain unpinned Linux perf CPU-cycle events.
After priming and before starting the scope, each case registers every live
decoder worker with sigbench. Sigbench sums userspace events for the calling
thread and those explicit workers; kernel and hypervisor cycles remain excluded.
This is participant-thread aggregation, not process-wide accounting. Wall time
above remains the end-to-end helper-thread latency measure. The audited
ReleaseSafe/ReleaseFast medians in events are:

- `fixed-contiguous`: 1,104,021.136/1,095,292.719.
- `fixed-fragmented`: 1,104,468.303/1,099,348.546.
- `chunked-trailers`: 1,107,972.881/1,102,880.781.
- `large-fixed-queue-pressure`: 1,855,326.418/1,831,613.361.
- `large-chunked-backpressure`: 1,872,740.377/1,734,364.156.
- `multipart-fixed-stream`: 1,130,064.120/1,110,767.230.
- `multipart-multi-mailbox`: 1,145,106.455/1,120,556.776.
- `two-slot-multistream-contention`: 21,127.871/8,093.093.
- `malformed-rejection`: 2,158,610.985/2,154,739.015.
- `decoded-limit-rejection`: 2,160,932.091/2,155,126.642.

The one-slot benchmark profile records a 2,389,632-byte worker slab, a
608-byte multipart parser, a 2,114,152-byte body workspace, a 1,184-byte
chunked workspace, a 512-byte receive buffer, a 512-byte decoded mailbox
capacity in 640 bytes of storage, a 3,136-byte decoder slot, and a requested
262,144-byte decoder stack. These are compile-time profile costs, not hidden
per-request allocations. All six companion `metrics.json` files are byte
identical with SHA-256
`1774ef870ea02e6d62137455e052a35938d76fe49764ee1cf0f74efe47d450b0`.

The aggregate SHA-256 values over the path-sensitive checksum manifests are:

```text
wall time    730908a58ac583ecc03657a7da3fa4c52857aaf45b535eab60c5029dc263f3df
TSC cycles   16e7162849e1ec49ae2ca70bb14d78e23a7d61d6d3271d8310628e260d07bd59
Linux perf   74a3766e19fe2328fc097c0b15746ec44a16f1f44af8e51af2de9b8d7e30647a
all M8       02ce9018b339df01820635938a37cb79880b0d25d328e7c8cff34d0896487a16
```

These cover 60, 20, 40, and 120 files respectively. To reproduce a manifest,
change to `zig-out/sigbench`, pass exactly the component roots listed below to
this function, and retain paths relative to that directory:

```sh
hash_component() {
  find "$@" -type f \
    \( -name sample.json -o -name estimates.json \) -print0 |
    LC_ALL=C sort -z |
    xargs -0 sha256sum |
    sha256sum
}
```

Raw M8 artifacts remain under:

- Wall time: `{release-safe,release-fast}/gzip-request-driver`,
  `{release-safe,release-fast}/m8-multipart-driver`, and
  `{release-safe,release-fast}/m8-multipart-parser`.
- TSC: `{release-safe-cycles,release-fast-cycles}/m8-multipart-driver` and
  `{release-safe-cycles,release-fast-cycles}/m8-multipart-parser`.
- Linux perf: `{release-safe-perf,release-fast-perf}/gzip-request-driver`.

M9 retains the first-party `FileSink` benchmark as a real 64 KiB io_uring
transaction. Each case starts its worker runtime before measurement, then opens,
writes, finishes, commits, verifies, compensates, and proves handle and staging
quiescence. The four cases cover anonymous and named staging crossed with
buffered and crash-durable publication. Every measurement has 100 samples in
ReleaseSafe and ReleaseFast.

The wall-time medians and 95 percent median confidence intervals in nanoseconds
are:

- anonymous buffered: 15,796.289 [15,621.811, 16,103.940] / 15,783.057
  [15,616.822, 16,252.557].
- anonymous crash-durable: 777,828.800 [751,233.880, 809,481.009] / 777,023.131
  [750,923.617, 820,135.812].
- named buffered: 17,124.697 [16,872.577, 17,405.479] / 16,933.044
  [16,787.165, 17,203.292].
- named crash-durable: 780,839.343 [773,042.683, 814,210.805] / 780,528.770
  [774,113.122, 827,132.235].

Pinned serialized-TSC medians and intervals in cycles are:

- anonymous buffered: 67,792.074 [67,215.249, 69,280.115] / 66,443.351
  [66,004.312, 67,304.546].
- anonymous crash-durable: 3,345,579.079 [3,307,245.240, 3,455,141.509] /
  3,334,880.899 [3,293,210.601, 3,421,976.715].
- named buffered: 73,475.949 [72,709.682, 75,119.814] / 72,055.894
  [71,403.437, 73,579.910].
- named crash-durable: 3,352,652.950 [3,308,581.608, 3,472,354.512] /
  3,351,515.652 [3,308,814.364, 3,456,100.919].

Linux perf counts userspace calling-thread cycles and excludes kernel filesystem
work. Its ReleaseSafe/ReleaseFast event medians are 9,787.992/8,756.917,
14,485.376/12,337.551, 15,586.524/14,971.584, and
21,478.413/20,340.595 in the same case order. Process-memory RSS, PSS, and
private-byte deltas are zero with [0, 0] intervals in all eight mode/case pairs.
Sigbench allocator counters likewise report zero allocations, frees, resizes,
allocated bytes, live bytes, and peak live bytes in every pair. The allocator
result covers the benchmark's explicit counting allocator; the forked seccomp
integration test separately kills any request-path `mmap`, `mremap`, or `brk`.

The retained tree contains 40 `sample.json`, 40 `estimates.json`, and exactly
100 samples per case. It contains no leaked staging file, destination file, or
symlink. Path-sensitive SHA-256 manifests are:

```text
ReleaseSafe wall       cafd1f9e18f2324d5105ea7a19f1e8beda3029f7f597548337958dbe9ceef280
ReleaseFast wall       afcc44fc93461a341a138442aee01ab5bc7d514cfc79d621a6ce58bc06cef950
ReleaseSafe cycles     f7a7a41bcab2e2312b80cec1f7f6ff890499b94f79aaa31805a571dec98ba741
ReleaseFast cycles     20e79a542aa9db2e8b25e5bed47fb324778679d25fcade15ab63666f9f628f2e
ReleaseSafe perf       f980d6fc8d258f6d2f2156b9044ff9986d3ec4a105b3bd81a2ff785e0211cf00
ReleaseFast perf       37065ed90ad876b8aaf0afe621c000884d43593c9db43847107adaf3eba22999
ReleaseSafe memory     a9b8265bc0021ed8b995aafbcfa2d4fd8a85d030b648cac3260832d295fd3d48
ReleaseFast memory     98712e434bba88b244d1a4b70d11654eae73c5490576b5de9a131fa6a86d86fa
ReleaseSafe allocator  585bde19166529215dcc7306e803426d251379070383a6e3c82488975aba2064
ReleaseFast allocator  45fd0201e55ce977b4fb79678dfdf9bb7bd261e387ddc57ea1d3b2ff660ce130
all 80 raw JSON files  2119be43dbff6b03f8868f0ffc601458361316a7595d16076e81eae4ff4fd517
full 620-file tree     6ec349495decc6dd477d5957c85699fcc13a19f1f474ab75666b097f9128769a
```

These are local anchors from Zig 0.16.0 on Linux 7.1.3, Ryzen 9 9950X3D,
microcode `0xb404035`, CPU 15 pinned, governor `powersave`, and boost enabled.
The CPU was not isolated and durable cases were noisy. The artifacts remain at
`zig-out/sigbench/m9-filesink-final`; they are evidence, not a portable service
latency promise.

M9 also retains separate multipart route-classification and typed-operation
dispatch groups. Dense classification covers 1, 512, and 4,096 overall routes;
the 4,096 case contains exactly 512 multipart file routes and 3,584 legacy
multipart routes. Typed dispatch initializes a valid runtime once outside the
timed region, then calls production `peekSubmission` through the balanced
512-file-route dispatcher. First, middle, and last cases load their fixed route
ID through volatile storage. The all-routes case advances by 257 modulo 512 and
validates the complete route-ID checksum, preventing comptime or optimizer
pruning of the decision tree.

Both modes used the normal 100 samples, 100,000 bootstrap resamples, three-second
warmup, five-second measurement, and one job. ReleaseSafe/ReleaseFast arithmetic
mean estimates and 95 percent confidence intervals in nanoseconds are:

- classification 1: 0.181 [0.181, 0.181] / 0.180 [0.180, 0.180].
- classification 512: 1.652 [1.651, 1.653] / 1.619 [1.618, 1.620].
- classification 4,096: 1.617 [1.615, 1.619] / 1.620 [1.618, 1.622].
- typed first: 31.681 [31.658, 31.704] / 32.563 [32.482, 32.648].
- typed middle: 31.253 [31.232, 31.277] / 31.523 [31.436, 31.637].
- typed last: 31.523 [31.499, 31.548] / 31.641 [31.587, 31.705].
- typed all routes: 32.530 [32.479, 32.587] / 32.191 [32.132, 32.292].

Each mode retains seven `sample.json` and seven `estimates.json` files, with
exactly 100 samples in every sample file. Each complete mode tree contains 105
files. Path-sensitive SHA-256 manifests are:

```text
ReleaseSafe 14 raw JSON  7641350c81016b878ec1ffe2b24cf6b286a6a7a3e5646d7a3135c054dd0578d8
ReleaseFast 14 raw JSON  b2656a1ce5314e1d79ead85ed91470876a16ad733763c13be7a02156fa306853
all 28 raw JSON           86d385b990c3f8743e23af608a3517a162c37f65e75644dcd1eb266eeab99208
ReleaseSafe 105-file tree 6e94d80027e3936dfdd0e13ca3e7c6ac9ec96e42e6c0d0847844523544aa7779
ReleaseFast 105-file tree 677b3f67fa15041c38a52c653f39b18eb58df701bc3d199195a66c174a109314
benchmark source          2a51025e917a844471e4cc613258748220237782b5915e36772892a4696333f3
```

The artifacts remain under
`zig-out/sigbench/m9-dispatch-final/{release-safe,release-fast}`. Reproduce them
from repository root with:

```sh
zig build -Dbenchmarks=true bench-release-safe -- \
  --jobs 1 \
  --output-dir zig-out/sigbench/m9-dispatch-final/release-safe \
  operation classification
zig build -Dbenchmarks=true bench-release-fast -- \
  --jobs 1 \
  --output-dir zig-out/sigbench/m9-dispatch-final/release-fast \
  operation classification
```

These anchors used Zig 0.16.0 on Linux 7.1.3, the same Ryzen 9 9950X3D host,
all CPUs 0-31 eligible, governor `powersave`, and no process pinning or CPU
isolation. They validate representation scale and mode parity, not dedicated-
host service latency or a regression threshold.

M9 also retains the production upload-transaction state machine with a bounded
benchmark sink. `window-4x4k-out-of-order` fills all four 4,096-byte write
slots, completes their normalized write requests in reverse order, finishes the
file, and commits it. `commit-four` begins and finishes four staged files before
committing them in declaration order. `abort-four` begins and finishes the same
four files before aborting them in reverse order. Every iteration checks its
transaction report, sink counters, and bounded fingerprint.

Both modes used 100 samples, the normal 100,000 bootstrap resamples, a
three-second warmup, five-second measurement, and one job. ReleaseSafe/
ReleaseFast medians and 95 percent median confidence intervals in nanoseconds
are:

- `window-4x4k-out-of-order`: 1,787.817 [1,784.835, 1,806.886] / 1,760.087
  [1,756.107, 1,814.543].
- `commit-four`: 1,620.158 [1,617.009, 1,663.152] / 1,617.414
  [1,610.601, 1,680.862].
- `abort-four`: 1,598.854 [1,594.490, 1,633.771] / 1,584.152
  [1,579.246, 1,661.798].

The retained metrics record a 17,448-byte transaction, a 72-byte finalization
report, and a 16,384-byte retained write window made from four 4,096-byte
slots. Both mode copies of `m9-upload/metrics.json` are byte-identical with
SHA-256
`9e1aa0777512436456cb4084c2456804983da3902789eefebb0ff89f20425300`.
The benchmark source SHA-256 is
`24cccc42dcb58ce3d0d83667a20b9dba2c7ea835ce8b8c90a407f0653ec82064`.

Each mode retains three `sample.json` and three `estimates.json` files, with
exactly 100 samples in every sample file. Each complete mode tree contains 48
files. Path-sensitive SHA-256 manifests are:

```text
ReleaseSafe 6 raw JSON   3fbb483fe5a9cf9892697d39c7a8f99aadd338ec99f3ef9534ef2feb574b8dff
ReleaseFast 6 raw JSON   5f48500861b0f6ae0324009b66a1d8565ded1632978788e33a940edbb48184f9
all 12 raw JSON          6be5dafea9bf4b09f9c22f6abea794f047accf826770c20b017aa31f128f5050
ReleaseSafe 48-file tree 4566915dfeb72e0d001d4527aac6b975d096c3227a770cbdbae3cde659ffd241
ReleaseFast 48-file tree af385d91a6157931e112e2a4c70df55dac37dbb74cb3312c520c9a5196bc3a71
complete 96-file tree    58d9ae993384dfa06892625657fa7362899e0fe7c978e3bb10bfe718bcafd8b9
```

The artifacts remain under
`zig-out/sigbench/m9-upload-final/{release-safe,release-fast}`. Reproduce them
from repository root with one list-mode metrics prepass and three exact cases
per mode:

```sh
zig build -Dbenchmarks=true bench-release-safe -- \
  --list \
  --output-dir zig-out/sigbench/m9-upload-final/release-safe
for case in window-4x4k-out-of-order commit-four abort-four; do
  zig build -Dbenchmarks=true bench-release-safe -- \
    --sigbench-exact "m9-upload-transaction/${case}" \
    --sample-size 100 \
    --warm-up-time 3s \
    --measurement-time 5s \
    --jobs 1 \
    --output-dir zig-out/sigbench/m9-upload-final/release-safe
done

zig build -Dbenchmarks=true bench-release-fast -- \
  --list \
  --output-dir zig-out/sigbench/m9-upload-final/release-fast
for case in window-4x4k-out-of-order commit-four abort-four; do
  zig build -Dbenchmarks=true bench-release-fast -- \
    --sigbench-exact "m9-upload-transaction/${case}" \
    --sample-size 100 \
    --warm-up-time 3s \
    --measurement-time 5s \
    --jobs 1 \
    --output-dir zig-out/sigbench/m9-upload-final/release-fast
done
```

These local anchors used Zig 0.16.0 on Linux 7.1.3, Ryzen 9 9950X3D,
microcode `0xb404035`, governor `powersave`, and no process pinning. They
validate bounded state-machine cost and mode parity, not dedicated-host service
latency or a regression threshold.

M10 retains seven paired CSRF cases. Three unsafe-request gates match the last
entry in exact one-, eight-, and 64-origin sets. The other cases cover canonical
synchronizer admission, strict cookie selection, and bound HMAC-SHA256 token
issue and verification. Origin construction, key setup, and binding setup stay
outside timing. Every measured iteration validates its closed result.

The origin gate stores startup-canonical origin bytes and a slot-bound integrity
seal. Hot lookup validates every active entry while comparing those owned bytes;
it does not reparse configured origins. Independent differential tests retain
the slower parser as an oracle and cover percent-encoded numeric hosts, quoted
authorities, malformed escapes, forged host values, and entry corruption. The
change reduced the 64-entry ReleaseSafe median from 14,722.091 ns to 725.870 ns
and ReleaseFast from 8,958.718 ns to 586.146 ns without weakening fail-closed
behavior.

Both modes used 100 samples, three-second warmup, five-second measurement, and
one job. ReleaseSafe/ReleaseFast medians and 95 percent median confidence
intervals in nanoseconds are:

- origin gate 1: 288.569 [283.569, 295.421] / 199.725 [198.370, 205.170].
- origin gate 8: 335.569 [327.982, 343.097] / 242.086 [240.191, 245.495].
- origin gate 64: 725.870 [715.093, 751.620] / 586.146 [583.159, 593.966].
- synchronizer admission: 26.360 [26.202, 26.551] /
  20.099 [20.015, 20.428].
- signed cookie scan: 48.109 [47.560, 49.827] / 45.971 [45.487, 49.334].
- signed token issue: 671.709 [662.854, 694.681] /
  625.003 [622.579, 644.582].
- signed token verify: 704.936 [693.867, 719.020] /
  653.086 [649.989, 668.017].

The byte-identical metrics reports record a 48-byte request state, 2,312-byte
standard 64-origin set, 68-byte keyring, 32-byte session token, 32-byte login
binding, 43-byte encoded synchronizer token, and 88-byte encoded signed token.
Their SHA-256 is
`7aa3e823530f880a1c918041135c36ea6124a037ec123075d2d6be31e20074ff`.
Each mode retains seven `sample.json` and seven `estimates.json` files with 100
samples per case. Path-sensitive SHA-256 manifests are:

```text
ReleaseSafe 14 raw JSON  fce47e7f9b77b18e49903953cbe1d40935a4ecaebe1f82a95f4ab66da0ee5524
ReleaseFast 14 raw JSON  dd73b0a86e09cc59dc136a8249bd15c6d3d849f52930dc646d4d5e6b457038e2
all 28 raw JSON           332b31f6a47dc5f70244207a1e23931c98a3e9cb85f604b0e1c448475a15a64f
complete artifact tree   7688c47e3c620f3e533fc78d41ef67bcaf40a6ac235a60620fb524ee1265c94d
benchmark source         a4d86064e1211be3ebcf2703639c2fee38f4aa78815be86dea57170655b78c42
```

Artifacts remain under
`zig-out/sigbench/m10-canonical-final/{release-safe,release-fast}`. These local
anchors used the same Zig 0.16.0, Linux 7.1.3, Ryzen 9 9950X3D, microcode,
governor, and non-isolated host as the M9 anchors. They validate bounded
in-process costs and mode parity, not service latency.

M14 defines a paired 12-case `m14-route-index` group for the generated route
trie. Common-prefix miss, last-literal hit, 405 capability synthesis, and
OPTIONS capability synthesis each run against identical 1-, 512-, and
4,096-route graphs. Every timed iteration validates the closed selection
result; ReleaseSafe and ReleaseFast use identical graphs and case identities.
These cases still require exact-candidate measurements before they become
release evidence.

The companion 12-case `m14-route-overlap` group exercises OPTIONS, 405, and
miss selection against adversarial 64-, 256-, 1,024-, and 4,096-route graphs
whose literal and parameter shapes overlap. Each case validates its result and
the graph's computed visit and compared-byte bounds. This prevents a small
route-count-only benchmark from hiding structural backtracking growth; exact
candidate measurements remain M14 evidence.

A final local whole-suite validation ran all 209 cases separately in
ReleaseSafe and ReleaseFast. Each mode retained 209 `sample.json` and 209
`estimates.json` files under `zig-out/sigbench/full-current/{release-safe,
release-fast}`, with 30 measurements in every sample and identical relative
case paths. Both modes used a 50 ms warmup, 100 ms measurement window, and 32
analysis jobs. The modes did not run concurrently, so one mode could not
contaminate the other's measurements. This short-window run proves complete
case execution and mode parity; it is not the controlled-host ReleaseSafe
regression evidence required by M14.

Dedicated machines, scheduled CPU time, and maintained workloads are the cost.
Fast anchor cases provide change feedback; the CI and release contract assigns
the complete matrix and cross-machine runs.

Sources: [sigbench](https://github.com/ferrreo/sigbench),
[sigbench specification](https://github.com/ferrreo/sigbench/blob/0.0.5/docs/SPEC.md),
[TigerStyle][tiger-style],
[Gin production mode](https://gin-gonic.com/en/docs/faq/), and
[Express production guidance](https://expressjs.com/en/advanced/best-practice-performance/).

[tiger-style]:
  https://raw.githubusercontent.com/tigerbeetle/tigerbeetle/refs/heads/main/docs/TIGER_STYLE.md
