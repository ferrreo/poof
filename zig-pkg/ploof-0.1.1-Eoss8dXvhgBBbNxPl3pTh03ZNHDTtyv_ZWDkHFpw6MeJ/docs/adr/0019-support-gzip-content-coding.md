# Support gzip content coding

Ploof version one will support `identity` and `gzip` content codings for both
requests and eligible Responses. Request decoding will be incremental and will
enforce independent encoded and decoded byte limits. Malformed gzip receives
400, a limit violation receives 413, and an unsupported request coding receives
415.

An absent request `Content-Encoding`, or a combined field with no non-empty
members, means identity. Parsing combines physical field lines and ignores at
most 32 empty list members. Exactly one non-empty, case-insensitive `identity`
or `gzip` coding without parameters is accepted. A malformed coding or more
than 32 empty members receives 400. One unsupported coding or more than one
non-empty coding receives 415; version one never partially decodes a stack or
falls through to another decoder.

Body decoders observe the content-decoded representation under ADR 0070, never
gzip bytes or HTTP transfer framing.

Response encoding will implement `Accept-Encoding` weights, wildcard and
identity semantics, and `Vary: Accept-Encoding`. It will skip ineligible or
already encoded responses. Gzip workspaces will come from fixed per-worker
storage because Zig 0.16's encoder state is too large to store per connection.
Compression level, minimum body size, and any future inline-versus-offload
threshold will be selected by representative HTML and JSON benchmarks.

Automatic coding also preserves application representation metadata. A
`Cache-Control: no-transform` directive, status 206, any `Content-Range`, any
strong `ETag`, or any `Content-Digest`, `Repr-Digest`, legacy `Digest`, or
`Content-MD5` field makes the response ineligible. Ploof cannot transform the
bytes while leaving those range, validator, or digest fields truthful. A weak
`W/` entity tag remains eligible because it can intentionally group negotiated
representations. Build-time identity and gzip assets instead own distinct
strong tags for their exact bytes. Application-supplied `Content-Encoding`
still bypasses every automatic rule because the application owns that complete
representation.

Version one's automatic response coding applies only to finite bodies. A
missing or empty `Accept-Encoding` selects identity. Physical fields combine
as one bounded list; invalid syntax, parameters outside a valid `q` weight,
duplicate parameters, or an out-of-range weight receives 400 and closes.
The parser admits at most 64 non-empty and 32 empty members. Duplicate
appearances of the same case-insensitive coding are accepted only when their
weights are identical; conflicting weights are ambiguous and receive 400.
Explicit `gzip` and `identity` members override `*`; otherwise the wildcard
supplies gzip's weight, while identity remains weight one unless explicitly
forbidden by `identity;q=0` or by `*;q=0` without an identity override.

For an eligible body at or above the configured threshold, gzip wins a weight
tie with identity. A lower identity weight therefore permits gzip, while a
higher identity weight selects identity. If no available representation has a
positive weight, Ploof sends 406 and closes. Bodyless statuses and streams are
ineligible. On finite responses, an application-supplied `Content-Encoding` is
an explicitly owned representation and bypasses automatic negotiation rather
than being parsed or stacked by the framework. Version-one streams carry
identity bytes only and reject application `Content-Encoding`; a later typed
streaming coder can extend the producer chain without buffering the stream.

Below the configured threshold, automatic gzip is unavailable. Ploof selects
identity only when its weight is positive; an explicit `identity;q=0` therefore
receives 406 rather than an unacceptable unencoded response.

Every otherwise eligible finite response merges `Accept-Encoding` into its
typed `Vary` field, including below-threshold identity and capacity fallback,
so a shared cache cannot reuse that choice for a request that permits gzip.
HEAD performs the same finite negotiation and compression needed to emit the
hypothetical GET metadata, but suppresses representation bytes as usual.

Response compression initially runs synchronously on the owning worker after
all capacity has been reserved. It gains an offload pool only if paired
ReleaseSafe and ReleaseFast measurements show that the added handoff improves
representative tail latency; version one does not add speculative compressor
threads.

The initial 30-sample paired finite-response suite retains a 1,024-byte default
threshold and the fastest encoder level. At the threshold, compressible HTML
and JSON encode to 9.57% and 6.83% of input; below-threshold identity costs
about 95 ns in ReleaseSafe and 78 ns in ReleaseFast, versus about 66 us and
57 us for gzip. Default and best produce no smaller output on the level
fixtures, while fastest is best or effectively tied across the representative
ReleaseFast set.

The expanded suite has 42 cases in both release modes. Structured 16 KiB HTML
and JSON fixtures encode to 6,095 and 5,662 bytes; valid high-entropy UTF-8
fixtures encode to 13,372 and 13,330 bytes. It proves the standard 72 KiB
response staging profile with a 48 KiB source, the checked-bound-minus-one
preflight fallback, a post-compression tight-head fallback, and an 11-field
negotiated-identity response. ReleaseSafe and ReleaseFast companion
`metrics.json` files contain the same 42 records. Their SHA-256 is:

```text
b106ae58220f1de46f75474088ab405a42df9cdd1449075738eaf63064e83eb1
```

Raw estimates, samples, and metrics remain under
`zig-out/sigbench/{release-safe,release-fast}/response-gzip-finite/`.

The header-rich identity case also gates representation-policy scanning. A
naive merged scan regressed its ReleaseSafe median from 508.399 ns to
519.442–520.473 ns. Dispatching representation fields by name length before
case-insensitive comparison reduced the repeated median to
439.661–443.732 ns, 12.72–13.52% faster than the original multi-pass code.

The worker clears the entire compressor workspace after every attempted
response because its history and token state can retain representation bytes.
It also clears every compressor-touched staging byte outside the committed
response, including HEAD and framework-fallback paths. A request slot is never
released with a duplicate compressed member beyond its committed byte range.

Zig 0.16's inflater is synchronous and pull-based, so temporary input
exhaustion cannot be exposed as a resumable reactor state. Request inflation
therefore runs in a fixed startup-created decoder-thread and workspace pool.
Bounded producer/consumer queues let a decoder block for more compressed input
without blocking an io_uring worker. Receive loans are copied into request-owned
queue chunks and recycled immediately; neither decoder threads nor application
views retain provided-buffer loans.

Request-head reads use one-shot selected-buffer receives. A fragmented head
submits another one-shot receive only after recycling the completed loan. An
admitted identity body switches to multishot receive, while gzip body reads
remain one-shot so queue admission needs capacity for at most one complete
receive buffer. A one-shot completion carrying `IORING_CQE_F_MORE` violates the
reactor contract and closes the connection after recycling any attached loan.

Ploof wraps the standard raw inflater with its own strict gzip framing. The
wrapper validates reserved header flags, optional header fields and checksums,
decoded CRC32, and ISIZE, rejects trailing garbage, and accepts a bounded
configurable number of concatenated members. Encoded and decoded limits apply
across the whole member sequence. This preserves common Go and Node multistream
behavior while bounding empty-member CPU amplification.

Each decoder slot owns one fixed SPSC compressed-byte ring and one
receive-buffer-sized SPSC decoded-output mailbox. The io_uring worker
copies a whole receive loan only when the ring can accept it, then immediately
recycles that loan. A decoder thread sleeps on a direct Linux futex only while
its ring is empty or while one decoded mailbox chunk is borrowed by the worker.
It signals one worker-local nonblocking eventfd for decoded output, a terminal
result, or a crossed receive-capacity threshold; one-shot `POLL_ADD`
integrates that edge into the owning ring. The single owning worker drains the
eventfd before swapping every slot's coalesced signal byte. These operations
are one API so a caller cannot clear a signal and then consume its only edge.
A publication after its slot was scanned leaves the level-triggered eventfd
readable for the next one-shot poll.

Each futex sleep gate packs its epoch and WAITING bit into one atomic 32-bit
word. A producer advances the epoch and clears that exact waiter in one atomic
transition, waking only when the prior word carried WAITING. Separate epoch and
boolean atomics are forbidden: a delayed wake for an old epoch can otherwise
clear a newer waiter and strand a full input queue.

Each active job has a copied lease with a 64-bit generation. A finite buffered
body owns one output slice that stays stable, exclusive, and
application-inaccessible until the worker consumes the terminal signal and
acknowledges the job. Multipart instead borrows one mailbox chunk at a time;
that chunk stays stable until the worker feeds the parser and acknowledges it.
The decoder cannot publish another chunk before that acknowledgement, which
propagates bounded backpressure without an allocation or whole-body buffer.
Joining a decoder does not erase an occupied job. Cancellation is idempotent
and never releases its lease; it cancels both queues, wakes either blocked
producer, and the worker still consumes and acknowledges the terminal result.

Decoded multipart prefixes may reach request-local field or discard callbacks
before the gzip footer is available. Route completion cannot run until strict
gzip CRC32, ISIZE, concatenated-member framing, the HTTP message body, and the
multipart closing delimiter all validate. A parser rejection is copied into
the slot before cancellation and wins at terminal settlement; 400, 413, and
415 therefore survive output, receive, timeout, and decoder-terminal races.
Callback effects before completion must remain request-local and abortable.

Shutdown publishes a slot's `canceling` state before the release-store of its
shutdown flag. A decoder loop acquire-loads that flag before it acquire-loads
the state used by the same iteration. Observing shutdown therefore also
observes the preceding cancellation; observing the old false flag cannot make
the loop exit. Reversing the loads is forbidden because a decoder could retain
a stale idle state, observe the new shutdown flag, exit as stopped, and leave
an occupied quiesced job without a terminal result.

Threads, stacks, queues, and the eventfd are created before readiness and
omitted from a bodyless application. Pool stop is two phase: it first cancels
and joins every decoder producer while preserving occupied terminal jobs,
results, output, and coalesced signals; it closes the eventfd only after every
job is acknowledged and the external poll is retired. A quiesced pool accepts
only result inspection and acknowledgement, never new input or slot reuse.
Normal worker shutdown settles every request lease before entering this pool
stop. Fatal shutdown joins producers while leaving the eventfd open, then, only
after backend ownership is proven, consumes terminal signals, acknowledges
leases without submitting new I/O, retires the poll, and closes the eventfd.
An unresolved poll or lease leaves cleanup unproven and requires process exit
rather than clearing application storage or closing a possibly referenced
descriptor.

Deflate, Brotli, and zstd remain outside version one. Brotli has no Zig 0.16
standard-library implementation; zstd is decode-only there and has a much
larger default workspace. Adding either direction would therefore expand the
dependency, build, memory, fuzzing, and security surface.

Sources:

- [RFC 9110 field lines](https://www.rfc-editor.org/rfc/rfc9110.html#section-5.2)
- [RFC 9110 recipient list rules](https://www.rfc-editor.org/rfc/rfc9110.html#section-5.6.1.2)
- [RFC 9110 Content-Encoding](https://www.rfc-editor.org/rfc/rfc9110.html#section-8.4)
- [RFC 9110 message transformations](https://www.rfc-editor.org/rfc/rfc9110.html#section-7.7)
- [RFC 9110 entity tags for negotiated representations](https://www.rfc-editor.org/rfc/rfc9110.html#section-8.8.3.3)
- [RFC 9530 content and representation digests](https://www.rfc-editor.org/rfc/rfc9530.html)
