# Require explicit FileSink staging mode

`FileSink` defaults to `.anonymous_required`. During startup it performs a full
`O_TMPFILE`, publish-link, and unlink probe beneath the configured root using
the server's actual credentials. Serving does not start unless that complete
lifecycle works. The failure names the sink root and explains how to select the
explicit named compatibility mode.

The worker preserves that first-party `FileSink` failure after asynchronous
rollback as a fixed-size diagnostic. `Worker.uploadStartupDiagnostic()` returns
the failing sink registry index, exact root, selected staging and durability
modes, file mode, failed phase and operation, exact error name, and cleanup
outcomes. `render()` writes the complete operator message into caller-provided
storage without allocation. `Diagnostic.rendered_bytes_max` is the sufficient
caller-buffer size. A configured root is limited to 4095 bytes, matching the
maximum non-NUL Linux pathname accepted by the runtime, so the rendered message
has a compile-time bound and never truncates the root or compatibility hint.
The normal startup result remains the generic
application failure; custom sinks remain supported and do not need to expose a
`FileSink` diagnostic.

An anonymous upload has no directory entry while staged. Abort or process death
closes its final FD and lets the filesystem remove it. Commit links it directly
to the ADR 0095 resolved parent and basename; `linkat` does not replace an
existing destination. Ploof builds the source as the exact
`/proc/self/fd/<descriptor>` path and submits `linkat` from `AT_FDCWD` with
`AT_SYMLINK_FOLLOW`. It does not use `AT_EMPTY_PATH`, which would require
`CAP_DAC_READ_SEARCH`. The source path and raw descriptor remain private and
are derived from the same tracked anonymous handle. Ploof never silently
changes staging modes after startup or during a request.

An application can explicitly select `.named_staging` for a filesystem or
container that cannot support the full anonymous lifecycle. It configures a
pre-existing staging directory on the same validated filesystem. A per-worker
CSPRNG seeded at startup produces 128-bit names; creation uses `O_CREAT`,
`O_EXCL`, `O_NOFOLLOW`, and `O_CLOEXEC`. Commit uses
`renameat2(RENAME_NOREPLACE)` to the resolved destination, and abort uses
`unlinkat`.

The configured staging path is a validated relative path beneath the sink root.
Generated names use the reserved, versioned `.ploof-upload-v1-` prefix followed
by 32 lowercase hexadecimal digits. Eight exclusive-create collisions are the
bounded maximum for one file start. Probe-stage and probe-destination names use
separate versioned domains. The worker derives its generator from the supplied
256 bits of startup entropy plus the worker and complete sink configuration;
the generator allocates no memory and is cleared during shutdown. Runtime
startup borrows each per-sink entropy buffer only for the current call; sinks
must not retain its pointer. The worker securely clears its seed immediately
after the runtime registry accepts it, on later initialization failure, and
after a partial entropy-source failure. The registry keeps one copy only while
deriving sink runtimes, clears each mutable derivation buffer after its call,
and clears the registry seed on readiness, rollback, failure, and stop.

The normalized upload I/O vocabulary exposes `link` only for a tracked
anonymous file. `rename_no_replace` carries a tracked exclusively created
source file and is accepted only when its retained base incarnation and
BLAKE3-128 path digest match the supplied named-staging directory's current
incarnation and path. It has neither a general hard-link operation nor an
overwrite-capable rename variant.

Named staging can leave entries after a process or machine crash. Ploof reports
the mode and live staging counters, uses a recognizable reserved name prefix,
and documents operator cleanup. It does not scan and delete files automatically
because another Ploof process or an application could still own them.

The staging directory and every destination key in an active upload transaction
are service-owned namespaces. Another process must not replace those entries
while Ploof is finalizing or compensating them. Linux has no atomic operation
that unlinks a pathname only when it still names a particular open descriptor;
the tracked source handle, exclusive open provenance, private random name, and
no-replace rename close the in-process substitution paths but cannot make a
hostile external directory writer safe. Deployments that cannot enforce this
ownership must not use filesystem compensation as a security boundary.

This makes the crash-orphan tradeoff explicit. Anonymous staging is the safe
default; named staging preserves deployment compatibility without pretending to
have the same failure behavior.

Persistence of file and directory changes follows the independently explicit
ADR 0097 durability mode.

Sources: [`open(2)` `O_TMPFILE`](https://www.man7.org/linux/man-pages/man2/open.2.html),
[`linkat(2)`](https://man7.org/linux/man-pages/man2/link.2.html), and
[`renameat2(2)`](https://man7.org/linux/man-pages/man2/renameat.2.html).
