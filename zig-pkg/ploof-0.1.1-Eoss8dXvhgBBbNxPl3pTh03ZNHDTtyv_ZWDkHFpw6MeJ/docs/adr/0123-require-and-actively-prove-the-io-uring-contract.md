# Require and actively prove the io_uring contract

Linux 6.1 is the version-one floor. This refines ADR 0002 by making deferred
task work part of the required reactor contract. The kernel release is only an
early filter: the returned ring capabilities, successful resource
registrations, and bounded active operations are authoritative.

Each worker creates and submits through its own ring on the owning thread. The
required setup flags are `IORING_SETUP_CQSIZE`, `IORING_SETUP_SUBMIT_ALL`,
`IORING_SETUP_COOP_TASKRUN`, `IORING_SETUP_SINGLE_ISSUER`, and
`IORING_SETUP_DEFER_TASKRUN`. The completion queue has at least twice the
submission depth; exact power-of-two depths come from the validated startup
profile and representative benchmarks. The kernel must return the requested
capacities and `IORING_FEAT_SINGLE_MMAP`, `IORING_FEAT_NODROP`,
`IORING_FEAT_SUBMIT_STABLE`, and `IORING_FEAT_FAST_POLL`.

The reactor core requires `NOP`, `ACCEPT`, `RECV`, `SEND`, `SENDMSG`, `READ`,
`CLOSE`, `TIMEOUT`, `POLL_ADD`, and `ASYNC_CANCEL`. Every receive uses buffer
selection. Request heads use one-shot receive, identity bodies use multishot,
and bounded-queue body decoders use one-shot; a phase that still needs input
rearms only after a terminal completion and recycling any loan. Production
accept is single-shot and ADR 0073 bounds it to one operation backed by an
available connection slot. Each worker registers its actual provided-buffer
rings before serving. Ploof does not use legacy `IORING_OP_PROVIDE_BUFFERS` or
allocate one receive buffer per connection.
Completion normalization accepts `IORING_CQE_F_SOCK_NONEMPTY` only where Linux
defines it for accept or receive results; any unknown operation flag is fatal.

One comptime `ReactorCapabilityManifest` combines those requirements with only
the features present in the closed application graph. `StaticDir` and
`StaticFile` add `OPENAT2`, `STATX`, `READ`, and `CLOSE`. Every multipart sink
declares exact normalized `IoRequirements`, and route composition unions those
declarations. `open`, `write`, `link`, `unlink`, `rename_no_replace`, and `sync`
select `OPENAT2`, `WRITE`, `LINKAT`, `UNLINKAT`, `RENAMEAT`, and `FSYNC`;
`close` adds nothing because `CLOSE` is already a core requirement. `FileSink`
derives its declaration from staging and durability. Returning an undeclared
operation is a fatal framework `invalid_request`. An application that declares
none of these features neither probes their operations nor reserves their
pools. The same manifest drives probing, diagnostics, tests, and dead-code
elimination.

Startup creates every production-sized worker ring and registration before a
service listener becomes ready. `IORING_REGISTER_PROBE` rejects absent opcodes
but is not treated as proof of operation flags, registration policy, seccomp
permission, or filesystem behavior. Every ring must submit and reap a bounded
operation. The active proof signals one nonblocking close-on-exec eventfd,
reaps an exact one-shot `POLL_ADD` readiness completion, drains the exact
counter value, and closes the descriptor. One bounded loopback test then
exercises two completions from one multishot accept, provided-buffer multishot
receive, the selected send path, a short timeout, and cancellation with both
target and cancel completions reaped.

Worker-local decoder wakes use the same one-shot rule. A wake completion first
drains its eventfd and then atomically consumes all bounded per-slot signal
bytes before rearming `POLL_ADD`. Splitting those actions or consuming signals
first is forbidden because a concurrent publication could lose its only edge.
Shutdown joins signal producers while leaving the descriptor open, reaps both
the poll target and its cancellation, and only then closes the eventfd. Joined
decoder jobs remain addressable but immutable until the owning worker consumes
their terminal signals and acknowledges their leases. Fatal cleanup may perform
that settlement only after backend ownership is proven and must not submit new
I/O while doing so.

The multishot-accept check has one accept-specific cleanup state machine. After
its SQE is built, every failure path submits cancellation when needed and drains
a fixed completion bound until both target termination and cancel completion are
observed. Every exact positive accept result is closed, including results that
race cancellation. An unknown positive completion, missing terminal ownership,
or failed descriptor close marks cleanup as `process_exit_required`; the probe
never guesses that descriptor ownership was recovered.

After both terminal completions, an empty CQ is not itself proof of quiescence.
The ring uses `IORING_SETUP_DEFER_TASKRUN`, so cleanup makes one nonblocking
`IORING_ENTER_GETEVENTS` transition before accepting an empty poll. Reaching the
fixed completion bound is also unproven ownership and requires process exit.

Feature checks use the configured resources and credentials. A static root
gets a non-mutating `openat2` and `statx` check through the reactor seam. Each
`FileSink` performs ADR 0096's complete transient create, write, publish,
durability, and cleanup check for its selected mode. Anonymous mode proves the
actual procfd `linkat(..., AT_SYMLINK_FOLLOW)` path in the worker's mount
namespace; missing or restricted procfs is a named startup failure, never a
switch to privileged `AT_EMPTY_PATH` or named staging. Named mode neither probes
nor requires `LINKAT`. All active checks have an independent monotonic deadline
and leave no service listener or probe artifact on failure.

Any nonzero submission-drop or completion-overflow counter is a fatal runtime
invariant failure. `IORING_FEAT_NODROP` prevents ordinary CQE loss but cannot
make kernel memory exhaustion safe to ignore.

Fatal teardown aborts every known application workspace and clears sensitive
storage. It reports quiescence only when descriptor ownership is proven. A
tracked accept, an unresolved asynchronous close, or an unclassified positive
CQE produces `ProcessExitRequired`: the worker is failed rather than stopped,
no stale descriptor number is closed speculatively, and the hosting process
must terminate. The convenience runner exits nonzero on that report.

The library returns a fixed-size `StartupFailure`; it does not panic, exit, or
start another reactor. `startup.check` exposes cleanup status, and its caller
must terminate when `requiresProcessExit` is true. `startup.require` renders
every failure to stderr and exits nonzero. The diagnostic names the stable
Ploof error code, phase,
operation or registration, errno, requiring feature, worker, kernel, ring
sizes, and setup flags. Where readable, it also reports
`kernel.io_uring_disabled`, io_uring group policy, seccomp mode, `RLIMIT_NOFILE`,
`RLIMIT_MEMLOCK`, and requested resources. It distinguishes a proven policy
setting from possible seccomp, LSM, resource, or kernel causes and never claims
an ambiguous errno proves one of them. Every diagnostic states that there is no
fallback reactor.

`SQPOLL`, `IOPOLL`, pinned registered payload buffers, multishot accept into a
bounded direct-descriptor table, `SEND_ZC`, `SENDMSG_ZC`, `SPLICE`, receive
bundles, incremental provided-buffer consumption, NAPI busy polling, and shared
worker queues remain private benchmark candidates. Version one does not require
or expose them until sigbench demonstrates a representative benefit that
outweighs idle CPU, completion traffic, retained-buffer lifetime, memory
locking, and complexity.

The reactor-neutral internal seam exposes operation tokens, borrowed receive
chunks, normalized network and file requests, and cancellation lifetime. It
never exposes SQEs, CQEs, buffer IDs, setup flags, or kernel opcodes to handlers,
preserving the migration path from ADR 0001.

Sources: [`io_uring_setup(2)`](https://man7.org/linux/man-pages/man2/io_uring_setup.2.html),
[`io_uring` setup flags](https://www.man7.org/linux/man-pages/man7/io_uring_setup_flags.7.html),
[`io_uring_register(2)`](https://man7.org/linux/man-pages/man2/io_uring_register.2.html),
[`io_uring` multishot operations](https://man7.org/linux/man-pages/man7/io_uring_multishot.7.html),
and [Linux io_uring policy][linux-io-uring-policy].

[linux-io-uring-policy]:
  https://www.kernel.org/doc/html/latest/admin-guide/sysctl/kernel.html#io-uring-disabled
