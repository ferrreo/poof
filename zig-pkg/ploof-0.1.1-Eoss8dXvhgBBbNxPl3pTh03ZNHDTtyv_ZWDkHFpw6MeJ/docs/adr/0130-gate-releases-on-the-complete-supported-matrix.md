# Gate releases on the complete supported matrix

Ploof's certified production target is Linux x86_64-v3 with exact Zig 0.16.0
and ReleaseSafe. Debug and ReleaseFast remain required test configurations. The
runtime kernel floor is Linux 6.1. The release matrix records certification
minimums selected from active upstream stable and longterm lines at or above
that floor. At this decision, those thresholds are 6.1.177, 6.6.144, 6.12.95,
6.18.38, and 7.1.3.

Each matrix case records a numeric minimum, not an exact `uname -r` string.
Host and evidence checks compare the leading `major.minor.patch` tuple, ignore
distribution packaging suffixes, reject upstream `-rcN` prereleases, and accept
any higher kernel. Runner labels use `kernel-min-*` to make that lower-bound
meaning explicit.

The floor and highest thresholds each have Intel and AMD x86_64-v3 cases.
Intermediate thresholds are assigned across both vendors. A host may satisfy
more than one threshold; the matrix does not claim that its exact named series
was booted. Kernel variation remains useful diagnostic coverage when runner
inventory provides it, but it is not an admission requirement. Unsupported
architectures and CPUs fail at build or startup with a direct diagnostic.

Version alone does not prove support. ADR 0123's active io_uring capability
probe remains startup authority and rejects a host before listener readiness
when its operations, flags, registrations, memory locking, or behavior are
missing. Ploof admits Linux 6.1 or newer kernels that pass that contract. The
certified release evidence covers the named minimum cases; a defect unique to a
modified distribution kernel is best-effort until it reproduces on an upstream
kernel. There is no reduced fallback reactor.

Ploof's production module and canonical server do not link libc or liburing.
They use Zig's Linux syscall and kernel UAPI surface directly. The matrix has no
GNU-versus-musl dimension because that would test a dependency Ploof does not
have. Every change builds a standalone fixture with libc linking disabled and
inspects its ELF for an unexpected libc dependency or unresolved C symbol. An
application may independently link libc for another library; Ploof neither
requires nor prohibits that choice. Development tools, sanitizers, proxies, and
load generators may use their host runtimes without entering the production
package.

Any conforming HTTP/1.1 edge proxy may front Ploof. The certified deployment
profiles pin exact Caddy and nginx versions and exercise TLS termination,
forwarding trust, PROXY protocol version 2, compression, streaming, uploads,
drain, and request-smuggling canaries. Those products are representative
interoperability fixtures rather than dependencies or an exclusive proxy list.
An upgrade enters the manifest only after its profile passes.

Every change first runs a bounded untrusted lane on hosted workers. It checks
formatting, mechanically enforceable TigerStyle rules, documentation, licence,
package paths, dependency hashes, and the production dependency allowlist. It
builds Debug, ReleaseSafe, and ReleaseFast, the public examples,
archive-independent consumer fixtures, and libc-free fixtures in both release
modes. It runs unit, comptime,
compile-failure, golden, security-corpus, deterministic-reactor, and allocation
trap tests plus fixed-work native fuzzing. Failures retain the deterministic
seed or minimized input needed for replay.

Ploof keeps Zig's `lowerCamelCase` declaration convention and `TitleCase` type
convention. This is the deliberate naming exception to TigerStyle's
`snake_case`; source otherwise follows the mechanically applicable rules unless
an ADR records a narrower exception.

TigerStyle's 70-line function limit is measured over executable Zig function
bodies. A comptime type factory stops accumulating length after its returned
struct namespace begins; each contained method is measured separately. Three
startup-only layout factories retain reviewed declarative preludes above the
limit: `Application`, worker live-static `Enabled`, and worker `Storage`.
Splitting those declarations would add aliases without reducing executable
control flow. No other type factory is exempt. Retained counters, IDs, and byte
totals use fixed-width integers. `usize` remains at Zig memory
boundaries such as slice positions, `@sizeOf`, alignment, mmap lengths, and
syscall parameters. Intentionally blocking event loops assert live work, and
all data-structure probes have explicit bounds. The two-assertions guideline is
used to demand meaningful precondition and postcondition checks around mutation
and ownership transfer, not padding in pure comptime mappings or trivial
adapters. Build checks enforce Zig formatting; review enforces the semantic
rules that cannot be counted mechanically without false confidence.

A trusted lane runs only approved source on ephemeral isolated self-hosted
workers. Unreviewed fork code never receives secrets and never runs on a
permanent performance machine. This lane runs the floor and highest-threshold
cases through real io_uring, exercises filesystems and loopback networking,
proves deliberate startup failures, and runs the current Caddy and nginx
profiles. ThreadSanitizer exercises worker
coordination, logging, metrics, snapshots, and shutdown. Matched ReleaseSafe
and ReleaseFast sigbench anchors run on the dedicated controlled host;
ReleaseSafe remains the release gate.

Scheduled CI runs the full minimum-threshold matrix, including floor and
highest thresholds on both CPU vendors. It expands deterministic seed sweeps,
multiprocess fuzzing, the complete security and proxy suites, connection churn, saturation,
drain, and resource-plateau soaks. It runs the full microbenchmark and real-
runtime matrix. Two-machine deployment benchmarks may run weekly because they
require reserved physical client and server hosts; their lower frequency does
not permit release evidence to omit them.

A release candidate is the exact revision that will be tagged. It must have
complete required evidence with no unexplained skip, unresolved flaky result,
sanitizer report, fuzz crash, security failure, post-start allocation, resource
leak, package mismatch, or confirmed performance regression. It completes the
versioned release fuzz budget and 24-hour mixed-workload soaks at the floor and
highest minimum thresholds. ADR 0128 governs performance validity and
regression decisions.

Every external hardware, campaign, soak, performance, or deployment command
retains a tar with one version-one semantic manifest at its root. The
candidate's gate manifest fixes required optimization modes, case parity, host
roles, physical-host separation, fuzz work, topology, workloads, resource
plateau interval, proxy image IDs, and tool identities. Every declared host must
be Linux at or above the runtime floor and expose the cumulative x86-64-v3
features; proxy records must exactly match candidate matrix repository, tag, and
digest pins. Release verification reopens the tar and hashes every path-sorted
retained file before comparing those declarations with the candidate revision
and recorder host. Each
minimum-threshold soak declares an exact 86,400-second UTC interval which must
fit inside the recorder interval. A readable tar, short run, same-host
deployment, or self-selected subset is not release evidence.

Every gate is also bound to one canonical command. The recorder refuses to run
or verify a substituted command, including a no-op command that would otherwise
produce a passing report. Sigbench source identity and proxy test image identity
are exact policy tuples, not coordinated values that the package and test script
may redefine together. Evidence collection authenticates each GitHub source run
both before and after artifact download so a workflow rerun cannot replace the
artifacts between provenance validation and use.

Two-machine manifests hash both the stable OS machine ID and a protected runner
inventory ID for each physical role. Distinct values reject a repeated or
cloned OS identity and retain the reviewed inventory assertion. They are not
cryptographic proof of physical separation; access control and human review of
the protected inventory remain part of the release trust boundary.

Ploof publishes a deterministic source archive rather than an official binary
or container image. Release automation verifies the archive in clean consumer
fixtures, its explicit path allowlist, deterministic asset output, licences,
and absence of production dependencies. The signed annotated tag and archive
are accompanied by SHA-256 and Zig package hashes, an SPDX software bill of
materials, and provenance attestation. Release notes state the exact compiler,
CPU and proxy matrix, kernel minimums, required capabilities, migrations, security
changes, and benchmark manifest and results.

`SECURITY.md` documents a private reporting path and supported versions.
Disclosure is coordinated after a tested fix exists; the eventual advisory
states affected versions, impact, mitigation, and upgrade path. An embargoed
reproducer becomes a minimized public security-corpus regression after release
when publication is safe. Emergency security releases still pass every
relevant mandatory gate.

Before 1.0, the newest minor line receives all fixes. The immediately preceding
minor receives high and critical security backports for 90 days after its
successor; older lines are unsupported. Deployments must meet the documented
kernel floor and capability probe; newer stable patches are recommended but do
not silently raise that floor. Raising the kernel or CPU floor requires a Ploof
minor release before 1.0 and a major release afterward, with migration notes
rather than a silent startup-policy change.

This contract costs kernel images, two CPU vendors, ephemeral trusted runners,
dedicated benchmark machines, proxy upkeep, fuzz CPU, soak time, and release-key
operations. The normal pull-request lane stays bounded, while scheduled and
release lanes pay for the breadth needed by a mandatory io_uring runtime.

Sources: [Linux kernel releases](https://www.kernel.org/releases.html),
[Zig 0.16 release notes](https://ziglang.org/download/0.16.0/release-notes.html),
[GitHub self-hosted runner security](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners),
[GitHub artifact attestations](https://docs.github.com/en/actions/concepts/security/artifact-attestations),
and [GitHub private vulnerability reporting](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/report-privately).
