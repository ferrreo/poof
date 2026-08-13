# Reserve finite gzip capacity before compression

After response middleware, content negotiation, and the configured size check,
Ploof first proves enough free response capacity for the compressor's checked
worst-case gzip bound, then acquires one fixed worker gzip workspace. The
synchronous worker is the only pool mutator during compression, so this proof
is an exclusive logical reservation even though destination chunks are linked
only as the compressor fills them. A known capacity miss never touches or
clears the large workspace. It does not queue, allocate, or consume the
identity chain until both resources are secured.

For Zig 0.16's finite compressor, Ploof never flushes between source chunks and
uses this checked bound for an identity length `N`:

```text
18 + ceil((9N + 10 * max(1, ceil(N / 32768))) / 8)
```

The 18 bytes are the fixed gzip header and footer. Each Deflate block contains
at most 32,768 tokens; a fixed-code representation costs at most nine bits per
source byte plus a ten-bit block header and terminator, and Zig selects dynamic
or stored coding only when it is no larger. Arithmetic overflow rejects the
reservation before compressor initialization.

One Zig 0.16 x86_64 compressor workspace is 295,632 bytes aligned to eight:
230,096 bytes of compressor state plus its required 65,536-byte history. It is
startup-owned and receives no allocator. `finish` is called exactly once, then
only the destination sink is flushed; compressor-writer flushes are forbidden
because they add non-final blocks and invalidate the bound.

Exactly one workspace exists per gzip-enabled worker. The synchronous worker
cannot run two response compressors concurrently, so a pool or per-request
copy would add memory without adding capacity. The workspace is absent from a
gzip-disabled application and its complete byte range is securely cleared
after every acquired-workspace exit.

If either resource is unavailable and identity remains acceptable under
`Accept-Encoding`, Ploof sends the completed identity response and records a
capacity-fallback reason. If identity is forbidden, it sends the preallocated
503 response and closes. This makes overload consume bandwidth rather than fail
an otherwise acceptable representation, without creating a userspace wait
queue.

After reservation, compression reads identity chunks in order but retains that
chain until the compressed response head succeeds. This transactional source
permits the exact identity response to survive a late compressed-head capacity
failure without rendering twice, adding a counting pass, or copying the source.
The tradeoff is bounded transient occupancy of source plus actual destination
chunks. Those chunks already belong to the startup-owned pool, so this raises
pool pressure but not post-readiness allocation or RSS. Once the compressed
head succeeds, `finish` releases the identity chain and transfers only the gzip
chain to transport. A compressor, checksum, length, or other invariant failure
discards both chains and reaches the central framework 500 response; Ploof
never sends a partial gzip member.

Startup validation proves that a configured HTML maximum can coexist with its
complete worst-case gzip destination in the worker chunk pool. Runtime metrics
record source chunks, reserved and used destination chunks, and actual pool
high-water. This makes the retained-source cost visible and keeps capacity
fallback deterministic when other pending responses already occupy the pool.

Because response middleware has already completed, a framework compression
failure does not rerun the application's typed error mapper or response phases.
It replaces the uncommitted result with the preallocated generic 500 close
response, records that final status, and runs `after` exactly once with the
actual transport result. If even that preallocated response cannot be started,
the request aborts with no invented status.

Generic 406, 500, and 503 responses use the Application-wide response-head
maximum rather than a route's tighter logical profile. Gzip-enabled
Applications prove at comptime that this maximum can hold the largest generic
head. Compressed staging bytes are copied into their final wire position only
after the head succeeds; any non-overlapping source tail is then cleared.
Failure and HEAD paths clear the whole touched staging range.

The standard runtime reserves 72 KiB per request response buffer. Its 16 KiB
maximum head plus the checked worst-case bound for a 48 KiB source is 71,701
bytes, so that boundary compresses under defaults. Applications may select a
different startup limit through `response_bytes_per_request`; a known staging
miss takes the identity-or-503 path before acquiring or clearing the 295,632-
byte compressor workspace.

Metrics distinguish negotiated identity, below-threshold identity, capacity
fallback, compressed success, and compression failure. Benchmarks report gzip
workspace occupancy, reserved and used destination chunks, peak live bytes,
compression cycles per input byte, latency, response ratio, and fallback rate
for compressible and incompressible HTML and JSON. The deterministic companion
artifact records encoded lengths, ratios, outcomes, and fallback boundaries
for every Sigbench case without widening Sigbench's timing API.

Source: [RFC 9110 `Accept-Encoding`](https://www.rfc-editor.org/rfc/rfc9110.html#section-12.5.3).
