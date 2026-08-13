# Use fixed-state pollers for upload sinks

Every concrete upload sink declares fixed `Runtime`, `State`, `WriteState`,
`Summary`, and a closed error set. Route composition verifies their sizes,
initial values, and method signatures at comptime. The sink implements five
poll methods: `begin`, `write`, `finish`, `commit`, and `abort`.

Every sink also declares the exact normalized `IoRequirements` it may return.
Route composition unions those declarations into the closed reactor capability
manifest. Returning an undeclared operation is a fatal framework
`invalid_request`, even when the request is otherwise structurally valid.

Each poll method receives the address-stable mutable per-worker `Runtime`.
`Runtime = void` erases for sinks without worker resources. Non-void runtime
storage is initialized before listener readiness, rolled back in reverse on a
startup failure, and shut down only after every request poller and upload
finalizer is quiescent. Runtime-owned descriptors never move into request
state; request state may borrow them only through the explicit runtime pointer.

Each sink also declares fixed `StartupState` and `initial_startup_state`.
`runtimeStart` polls from a worker index and 256 bits of startup entropy to a
fully constructed `Runtime`; the runtime output cannot borrow either input or
startup state. `runtimeStop` polls the constructed runtime to completion. Both
methods use normalized `IoRequest`s, the sink's closed error set, and the same
one-request poller invariant as request work. Generated worker startup dedupes
identical configured sink types, starts them in declaration order, and rolls
back completed runtimes in reverse. Shutdown is the same reverse order after
request, cancellation, finalization, and tracked-handle quiescence.

A sink may provide `abandonRuntimeStart` and `abandonRuntimeStop` hooks for
secret-bearing control state. Ploof calls the matching hook exactly once after
an unsubmitted control request is removed from its poller and before owner
cleanup. The hook scrubs sink-owned secrets but cannot claim that any tracked
handle closed; the framework descriptor table remains the ownership authority.
The first-party `FileSink` uses both hooks to zero its BLAKE3 name-generator key.

Every sink declares `request_handles_max` and `runtime_handles_max` as `u8`
values from zero through sixteen. These are maximum concurrently owned handles,
not operation counts. Ploof registers a successful open in the poller's owner
ledger before delivering it to sink code and removes it only after a successful
close. Request and runtime ledgers are distinct. After sink failure and target
quiescence, framework cleanup closes every remaining owned handle before state
reuse; inability to prove close ownership requires process exit.

The public `FileHandle` is a compact logical slot and nonzero generation, never
a reusable Linux descriptor number. The worker's fixed file table maps it to a
descriptor and exact request or runtime owner. Every operation validates that
generation and owner before submission. A positive open is entered in the
worker table before completion normalization, so even an unexpected or malformed
upper-layer completion remains discoverable by fatal owner cleanup.

Every descriptor borrow returns a bounded generation-tagged lease. Completion
must consume that exact lease; a different request owner, a duplicate release,
or a stale lease cannot decrement another operation's reference. The table also
retains each open's creation mode. The normalized `link` operation is only the
publication of a handle proven to come from an anonymous open; it is not a
general hard-link primitive.

Each reserved logical handle receives a table-local nonzero `u64` incarnation.
Incarnations never wrap or repeat; exhausting the counter fails closed before a
new handle is reserved. Incarnation zero denotes only the working-directory
bootstrap base. An exclusive open retains its base incarnation and a 128-bit
BLAKE3 digest of the submitted path. `rename_no_replace` carries the tracked
source file handle; the transport resolves the supplied source directory's
current incarnation and requires an exclusively created writable file whose
retained identity matches before it borrows the syscall directories. This keeps
provenance fixed-size without retaining a callback-borrowed path and remains
exact when a compact public handle generation wraps.

The identity-borrow operation itself accepts only an explicit `.exclusive`
creation requirement. Ordinary and anonymous handles cannot enter the retained
identity path, even through an internal caller.

This proves framework provenance, not an atomic relationship between an open FD
and a later `renameat2` source-path lookup. A named staging namespace must remain
inaccessible to untrusted writers from exclusive creation through rename
completion; an unguessable name does not replace directory permissions. The
first-party `FileSink` securely resolves the directory and documents this as a
deployment precondition. It cannot prove that another process with the same
filesystem authority will not mutate the directory after startup. Security
tests cover the enforced in-process boundary and the external-writer limitation
explicitly. The real-io_uring regression renames the exclusively created stage,
places different bytes at its published path, and proves that `renameat2`
publishes the replacement while the retained FD still names the original. That
test makes the private-directory deployment precondition executable instead of
claiming an in-process check can defeat an equally privileged writer.

An open names either a tracked logical handle or the process working directory.
The working-directory base exists only to bootstrap a worker runtime root and
accepts only the runtime-control owner opening a read-only directory without
creation. Its path may be non-empty, absolute, or relative. An absolute
bootstrap path cannot request `RESOLVE_BENEATH`. After bootstrap, sink paths
remain relative to tracked handles; the reactor enforces their exact runtime or
request owner.

Each method receives either its typed start input or the completion of the one
I/O request that poller previously submitted. It returns either a completed
typed output or one normalized reactor-neutral `IoRequest`. A completion can
lead to another request, allowing each phase to be a bounded manual state
machine without a coroutine, future allocation, or paired start/completion API
for every operation.

There is one exact exception to sink completion delivery. When the framework
has submitted cancellation for a target, the matching target entry records
`cancel_submitted`. If that target then completes with `.canceled`, Ploof
consumes the completion and abandons the poller's proven pending request without
calling the sink continuation or retrying the request. Sink state remains
intact for abort finalization and framework owner cleanup. A target success in
the target-success/cancel-`not_found` race is delivered normally, as is a
spontaneous `.canceled` target without matching `cancel_submitted` provenance.
Both the target CQE and its cancel CQE are always reaped before their transport
ownership is released.

One lifecycle poller runs `begin`, `finish`, `commit`, and `abort` for a sink
instance. Each ownership-transferred chunk uses one independent write poller,
so ADR 0082's configured window can make progress concurrently. Only one
request may be outstanding per poller. Normalized upload writes have write-all
semantics: Ploof handles short kernel writes while retaining the chunk and its
`WriteState` until the complete chunk succeeds or fails.

When the multipart parser pauses on asynchronous work, the worker submits every
ready poller up to that route's window. While capacity remains, it resumes the
parser immediately and the connection bridge consumes any retained body tail.
This synchronous refill path is bounded by the public hard maximum of 16 window
slots. Once full, only a completion can release a slot and resume parsing.

A parser rejection discovered after asynchronous resume is still a request
outcome, not a worker failure. Invalid multipart or field input maps to 400,
limits map to 413, and unsupported media maps to 415. The worker records an
upstream body abort, cancels every active sink target, and waits for transaction
finalization before the connection sends the rejection and closes. Only an
internal fatal source enters the process-fatal ownership path. If the parser
became complete during resume, the application lifecycle records that state so
the fixed, chunked, and gzip transport EOF paths prepare the response without
calling the parser's finish transition twice.

Generated adapters retain framework-failure provenance separately from the
sink's error value. A sink may legitimately declare an error name also used by
a poller or adapter invariant; that name collision cannot turn an invalid
request, mismatched completion, or unproven ownership into a recoverable sink
failure. Fatal provenance makes the request workspace non-reusable and reaches
the process-fatal ownership path when cleanup cannot be proven.

The transaction boundary preserves the same rule even when a sink declares
`error.TransactionFatal`, because Zig error names are global. Callers classify
every returned transaction error with `failureKind`; the transaction's latched
fatal state, not the raw error name, is authoritative. A sink collision remains
an abortable sink failure, while every framework invariant latches fatal state
before returning.

Ploof, not the sink, owns io_uring submission, SQE capacity, operation IDs,
`user_data`, cancellation, CQE reaping, metrics, and buffer release. Public sink
code never receives a ring, SQE, CQE, or backend-specific cancellation token.
Cancellation does not release state or buffers until both the target operation
and any cancellation operation have been reaped. Abort begins only after prior
pollers are quiescent.

The first-party `FileSink` retries canceled abort and compensation closes below
a shared bound of eight canceled close completions per request. The eighth
cancellation latches state-scoped `invalid_request` provenance and leaves the
still-open handle to framework owner cleanup. This is fatal, so the request
workspace is never reused. Even when owner cleanup closes the request handle,
the live runtime counter and root handle make worker ownership incomplete and
require process exit; any failed owner close independently requires process
exit. Two ordinary cancellations followed by success remain a recoverable
cleanup failure with reconciled counters.

Every slice referenced by a returned request remains stable through its final
completion. Paths live in fixed `State` or `WriteState`; upload write bytes live
in the owned window slot. Ploof retries short writes itself and delivers one
write-all completion to the sink. A successful open transfers a tracked handle
to that sink instance. Close retires it; after abort or a sink failure Ploof
closes any handle still tracked to the instance, so a malformed custom sink
cannot leak a descriptor across request-workspace reuse.

Typed start inputs other than `WriteInput.bytes` are callback-borrowed. A sink
copies any path, metadata, or other slice it needs after that call before it
returns either `done` or an I/O request. The owned upload slot behind
`WriteInput.bytes` remains stable until that write poller completes, including
every request, retry, cancellation target, and terminal CQE.

The request workspace contains state and fixed summaries for every occurrence
that can remain staged, one lifecycle operation descriptor, and only the route
window's number of maximally sized `WriteState` slots. The slots can be shared
across file declarations because only one multipart part is active at a time.
State pointers are recorded only after the workspace reaches its stable address;
the transaction cannot be copied after recording its first begun sink.

The normalized request vocabulary is a separate I/O-seam decision. Restricting
sinks to that seam makes later reactor migration possible and centralizes
cancellation correctness, at the cost of explicit state-machine code and no
escape to arbitrary raw io_uring operations.

Transaction finalization uses one lifecycle poller at a time under ADR 0093.
The first-party `FileSink` validates this extension seam under ADR 0094.
