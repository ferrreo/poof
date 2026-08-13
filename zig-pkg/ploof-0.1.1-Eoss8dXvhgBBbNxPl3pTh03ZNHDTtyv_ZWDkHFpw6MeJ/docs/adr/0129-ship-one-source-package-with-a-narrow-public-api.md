# Ship one source package with a narrow public API

Ploof is one BSD-3-Clause Zig source package rather than a prebuilt static or
shared library. Its `build.zig.zon` declares package name `ploof`, one permanent
tool-generated fingerprint, the release's semantic version, minimum Zig version
0.16.0, content-hashed dependencies, and an explicit path allowlist containing
only required build files, source, tools, documentation, examples, and licence
material. A release archive is immutable.

The package exposes the production module `ploof`, the test-only module
`ploof_testing`, and the host artifact `ploof-assets`. An application owns its
executable, root module, target, optimization choice, and build graph. Ploof
does not ship a project generator, take over the application build, promise a
C or binary ABI, or require a separately installed server executable.

`ploof` is the only production import. Its curated root re-exports the closed
application and route declarations, typed request and response facilities,
middleware, body codecs, JSON, HTML templates, assets and static files, proxy
and browser-security policy, observability, lifecycle, and bounded runtime
configuration. There is no core/full split, plugin ABI, runtime facility
registry, or package feature matrix. Comptime composition and dead-code
elimination remove facilities an application does not declare.

Routes, decoder schemas, middleware composition and state layout, templates,
assets, response capabilities, limits, and the runtime-capacity profile are
compile-time application data. Listener addresses, worker count, startup
policies, and one caller-owned concrete `ApplicationState` value are supplied
during startup. Startup reports the fixed profile's per-worker and process-wide
memory budget; changing a pool or ring capacity recompiles the application.
Handlers and middleware receive that state explicitly through generated typed
interfaces. Ploof does not provide `locals`, an `anyopaque` dependency
container, or implicit global state. An application that mutates state shared
by workers owns the required synchronization.

Only declarations intentionally documented and re-exported from `ploof` form
the production source API. `src/internal` files, reactor seams, layouts,
benchmark adapters, build symbols, and direct dependency-path imports carry no
compatibility promise. Public documentation, examples, and compile fixtures use
only the exported surface. Several standalone consumer fixtures fetch the
actual release archive and build minimal, full-featured, and failing-diagnostic
applications so repository-relative imports cannot hide packaging errors.

`ploof_testing` exposes a bounded high-level test client that drives an
application's production routing, middleware, binding, handler, and response
state machines through the private deterministic test reactor. It exposes
neither completion scheduling nor a reactor interface usable in production.
It accepts caller-owned test storage or allocator explicitly, and its test-only
conveniences do not weaken the production allocation contract. Importing
`ploof` cannot compile this module into an application accidentally.

`ploof-assets` is a host build artifact invoked through an explicit Zig build
DAG edge only when an application configures embedded assets. Given enumerated
input files and finite limits, it emits one cached generated Zig module with
ADR 0120's content identities and ADR 0121's deterministic identity and gzip
representations. It performs no network access, invokes no system compressor,
writes no application source-tree file, and has no runtime role. Ploof supplies
short documented build wiring without replacing the application's `build.zig`.

The documented wiring passes `--output` immediately before Zig build's
`addOutputFileArg`, supplies every source with `addFileArg`, and imports the
returned cached file as one module. The complete CLI, finite limits, media
table, generated records, diagnostics, and exit statuses are specified in
`docs/ASSETS.md`.

The production module and asset compiler use only Ploof source, the Zig 0.16
standard library, and direct supported kernel interfaces. They require no
`liburing`, OpenSSL, zlib, external C library, dynamic lookup, or system package.
Caddy and nginx are integration-test programs rather than Zig dependencies.
Attributed protocol corpora are test data rather than linked code.

Sigbench 0.0.5 is an exact-tag-URL, exact-content-hash, lazy, benchmark-only
dependency with a Zig 0.16 package manifest and named module. Explicit
`-Dbenchmarks=true` activation keeps normal consumer fetches and builds from
fetching or compiling it. Ploof does not vendor a copy or expose sigbench
through its modules. Any future production dependency needs an ADR covering
necessity, licence, provenance, supply-chain risk, memory, performance,
fuzzing, and removal cost.

Ploof begins at version 0.1.0. Before 1.0, patch releases preserve documented
source API and observable behavior except for a security correction that cannot
be made safely without a break; such an exceptional break is called out rather
than hidden. Minor releases may add or break public APIs, and every break ships
with migration notes and compile-tested before-and-after fixtures. Version
1.0.0 begins ordinary Semantic Versioning for the declared public API.

The initial supported compiler is exact Zig 0.16.0 even though the manifest
states it as the minimum. A later 0.16 patch enters the supported range only
after the complete CI matrix passes. Supporting Zig 0.17 starts a new Ploof
minor line rather than accumulating compiler-version branches inside hot code.
Unsupported Zig versions, non-Linux targets, non-x86_64 architectures, or
targets missing x86-64-v3 fail during the build with direct diagnostics. Kernel
and io_uring capability remain runtime startup checks. ReleaseSafe is the
documented production optimization mode.

This policy versions all first-party facilities together and makes public test
and build surfaces compatibility obligations. It avoids dependency drift,
plugin ABI constraints, hidden code generation, and uncertainty about which
source declarations applications may rely on.

Sources: [Zig build system](https://ziglang.org/learn/build-system/),
[Zig 0.16 package identity changes][zig-package-identity],
[Semantic Versioning](https://semver.org/spec/v2.0.0.html), and
[sigbench 0.0.5 tree][sigbench-tree].

[zig-package-identity]:
  https://ziglang.org/download/0.16.0/release-notes.html#Ability-to-Override-Packages-Locally
[sigbench-tree]:
  https://github.com/ferrreo/sigbench/tree/0.0.5
