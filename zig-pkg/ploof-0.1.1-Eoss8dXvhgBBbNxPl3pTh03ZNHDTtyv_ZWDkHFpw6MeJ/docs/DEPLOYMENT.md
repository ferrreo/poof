# Deploying Ploof

Ploof 0.1 is a plaintext HTTP/1.1 application server. Terminate TLS and
client-facing HTTP/2 or HTTP/3 at a reverse proxy, then use HTTP/1.1 on the
trusted hop to Ploof. The origin listener should normally bind loopback or a
private interface that is unreachable from untrusted networks.

ReleaseSafe is the supported production optimization mode. ReleaseFast is a
benchmark and diagnostic comparison; it is not the production default.

## Host contract

A deployment needs:

- Linux x86_64 with the x86-64-v3 feature set;
- the exact Zig 0.16.0 compiler for source builds;
- Linux 6.1 or newer; and
- every io_uring flag, feature, opcode, and active behavior required by the
  compiled application.

Ploof makes direct Linux syscalls and links neither libc nor liburing. Startup
actively probes the required io_uring contract before reporting readiness.
There is no poll, epoll, blocking-I/O, or reduced-feature fallback. Failure is
reported as a bounded `PLOOF startup failure` diagnostic and the process exits
without serving.

Build the application with its own root build step in ReleaseSafe. Verify the
resulting ELF and a clean package consumer through Ploof's release gates; do
not substitute a binary built for a generic x86-64 CPU.

## Process ownership

Use `ploof.ServerRunner` for the normal one-server process. It consumes
SIGTERM and SIGINT with `signalfd`, begins an irreversible graceful drain, and
then applies the configured forced-shutdown deadline. `runOrExit` writes a
bounded diagnostic to standard error and returns a stable nonzero exit status
for startup, incomplete shutdown, or process-control failure.

The runner and its contained server own address-sensitive, cache-line-aligned
state. Keep the value at one stable address for its whole lifetime:

```zig
const Runner = ploof.ServerRunner(App, .{ .workers_max = 8 });
var runner: Runner align(@alignOf(Runner)) = Runner.init();
```

The same rule applies when using `ploof.Server` directly. A global declaration
must spell the explicit type alignment; do not return, copy, or move a server
after `start`.

Default shutdown budgets are 30 seconds of graceful drain followed by 5
seconds of forced cancellation. Override them in startup configuration when
the proxy and service manager use different budgets:

```zig
runner.runOrExit(&state, .{
    .worker_count = 8,
    .shutdown = .{
        .grace_ns = 20 * std.time.ns_per_s,
        .force_ns = 5 * std.time.ns_per_s,
    },
});
```

Give the process manager a termination timeout longer than the sum. During
graceful drain, readiness becomes false before active work is drained. A
second signal advances forced cancellation. An incomplete drain is a process
failure, not a successful stop.

## Listener and reverse proxy

The listener defaults to `127.0.0.1` and an ephemeral port. Production should
set a fixed private port and keep the origin outside the public firewall:

```zig
.listener = .{ .address = .{ .ipv4 = .{
    .bytes = .{ 127, 0, 0, 1 },
    .port = 8080,
} } },
```

Ploof never guesses whether a peer is a proxy. Select no forwarding fields,
RFC `Forwarded`, or the `X-Forwarded-*` family at startup. Only a peer matching
the fixed trusted address/CIDR list can rewrite client, host, or scheme
metadata. Fields from other peers are ignored when direct peers are allowed,
or the connection is rejected when the profile requires a trusted peer.

For a local Caddy or nginx hop using `X-Forwarded-*`:

```zig
.forwarding = .{
    .family = .x_forwarded,
    .trusted = &.{"127.0.0.1/32", "::1/128"},
},
```

Trust the narrowest actual proxy source. Do not trust an entire container,
cluster, or private-network range merely because it is private. If an
untrusted client can connect from a trusted address range, it can forge the
effective scheme, host, and client identity used by redirects, CSRF, logging,
and application policy.

Ploof accepts PROXY protocol only in explicit v2-required mode. Every
connection on that listener must then carry a valid v2 preface from a trusted
peer:

```zig
.forwarding = .{
    .proxy_protocol = .v2_required,
    .family = .x_forwarded,
    .untrusted_peer = .reject,
    .trusted = &.{"127.0.0.1/32"},
},
```

Do not enable PROXY v2 on a mixed direct/proxied listener. Ploof does not
auto-detect it.

### Caddy origin

This minimal shape terminates TLS and forces HTTP/1.1 to the origin. Caddy
sets the `X-Forwarded-*` family for the upstream request; remove incoming
`Forwarded` so only one family has authority.

```caddyfile
example.com {
    reverse_proxy 127.0.0.1:8080 {
        header_up -Forwarded
        transport http {
            versions 1.1
            compression off
        }
    }
}
```

### nginx origin

Disable request and response buffering when application streaming semantics
must reach the origin and client without proxy-sized staging:

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $http_host;
    proxy_set_header Forwarded "";
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Forwarded-Host $http_host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_request_buffering off;
    proxy_buffering off;
}
```

Align proxy request-head, body, idle, and response timeouts with Ploof's
compiled bounds. A proxy may impose smaller public limits, but it must not
silently promise clients a larger body or longer stream than the origin can
accept. Ploof's own gzip request and response support remains bounded; avoid
configuring an edge policy that transforms content in ways application-level
ETags or content-coding policy do not expect.

Ploof decodes valid percent escapes before routing without cleaning dot
segments or repeated slashes. Do not authorize a path at the proxy and then
route the same request in Ploof unless their normalization behavior is proven
identical for encoded `/`, encoded `\\`, double escapes, and encoded dot
segments. Prefer one authorization boundary; a proxy rule that sees different
path bytes from the application can create an authorization bypass.

The repository's pinned Caddy and nginx fixtures exercise TLS termination,
keep-alive, hostile forwarding fields, gzip, streaming responses, multipart
streaming, X-Forwarded identity, and Caddy PROXY v2. Run them before changing
the proxy profile:

```sh
zig build test-proxy-interop -Dproxy-interop-required=true
```

## Health and metrics

No management path is reserved automatically. Add liveness, readiness, and
OpenMetrics routes to the normal typed route graph, then restrict them at the
proxy or with application middleware.

```zig
const State = struct {
    readiness: ploof.Lifecycle.Readiness = .{},
};
const Context = ploof.Context(State, ploof.response.standard_head_limits);

fn readinessFor(state: *State) *const ploof.Lifecycle.Readiness {
    return &state.readiness;
}

const Live = ploof.Health.Liveness(Context);
const Ready = ploof.Health.Readiness(Context, readinessFor);

const App = ploof.Application(.{
    .State = State,
    .routes = .{
        ploof.get("/live", Live.handle),
        ploof.get("/ready", Ready.handle),
        ploof.openMetrics("/metrics"),
    },
});
```

Bind readiness when starting:

```zig
.readiness = &state.readiness,
```

Liveness returns 204 whenever its handler runs. Readiness returns 204 only
after complete startup and returns 503 while starting or draining. OpenMetrics
uses a bounded single-snapshot service; a concurrent or expired scrape returns
503 rather than blocking request workers or exposing a partial snapshot.

Metrics labels contain only fixed route patterns and closed enums. They never
contain raw paths, query strings, hosts, addresses, headers, bodies, filenames,
or user identities.

## Access logs

Access logging is disabled at compile time by default. Enable fixed per-worker
rings in server options and supply an already-open, writable `O_NONBLOCK` Linux
pipe or socket descriptor at startup:

```zig
const Runner = ploof.ServerRunner(App, .{
    .workers_max = 8,
    .access_log = .{
        .enabled = true,
        .ring_capacity = 1024,
        .drain_batch_per_ring = 64,
    },
});

// In StartConfig:
.access_log_descriptor = access_log_fd,
```

The first-party path formats bounded NDJSON without allocating after startup.
It records method, static route identity, status, closed outcome, duration, and
wire/decoded byte counts. It deliberately excludes request-controlled text and
identity data. Full rings or a failed sink drop records and increment loss
counters without blocking request processing; this is operational telemetry,
not a durable audit log.

Use a collector on the other end of the pipe or socket to write and rotate log
files. Direct regular-file sinks and blocking descriptors are rejected at
startup because Linux does not give regular-file writes bounded nonblocking
semantics. Preserve descriptor lifetime and do not clear `O_NONBLOCK` until
shutdown completes. Enabled logging without a descriptor, a read-only sink, or
a descriptor supplied to a build with logging disabled is a startup error.
The logger thread blocks `SIGPIPE` before startup succeeds, so collector
disconnect becomes a counted sink failure rather than process termination.

## Capacity and memory

All framework request-path capacity is compiled into the `Server` type or
created before readiness. Important per-worker limits include connection and
request slots, body and chunked workspaces, receive buffers, pipeline bytes,
finite response bytes, response chunks, gzip decoders, upload windows, static
file slots, and io_uring entries. There is no runtime growth or heap fallback.

Start with defaults, measure saturation and high-water metrics, then change
only the exhausted bound. Multiplying every bound can make the caller-owned
server value and thread stacks needlessly large. The successful `Server.start`
result contains an exact fixed-memory report, including per-worker caller-owned
storage, io_uring mappings, provided buffers, requested helper stacks, total
known process bytes, route-search scratch, static route-index bytes, and
`@sizeOf(Server)`. Route-search scratch is already included in the worker
storage total; its named field exists for capacity review and must not be added
again. Record that report with deployment configuration and reject unexpected
changes in review.

Application handlers, state, and custom sinks are outside Ploof's allocation
guarantee. Keep their storage bounded if the complete service needs the same
post-readiness zero-allocation contract.

Raw, decoded, multipart, JSON, form, template, response, and file limits are
route or application declarations. The standard multipart total is 16 MiB,
not a hard library ceiling; applications can select another checked finite
limit. A rejected or saturated capacity returns a defined bounded outcome and
never allocates an overflow buffer.

## Assets and files

Use `ploof-assets` to embed enumerated CSS, JavaScript, and other immutable
files at build time. Generated fingerprinted routes support validators and
precompressed gzip representations without filesystem access. See
[ASSETS.md](ASSETS.md) for build wiring and typed template references.

Use confined live-static routes only for content that must change without a
rebuild. Roots are opened before readiness and requests are resolved beneath
those descriptors. Do not grant the service broader filesystem permissions
than the declared roots and upload staging directories need.

`Multipart.FileSink` uses application-created storage keys, `openat2`
confinement, transactional staging, no-replace publication, and explicit
durability policy. Client filenames are metadata, never storage paths. Keep
upload roots on the intended filesystem, size proxy and Ploof body limits
consistently, and leave proxy request buffering off when uploads must stream.
Anonymous staging is the safe default. Named staging is safe only when its
directory remains service-owned and inaccessible to untrusted writers from
exclusive stage creation through final rename; a hostile writer with access to
that namespace can replace the staged pathname before publication.

## Pre-deployment checks

Before deploying a candidate revision:

```sh
zig build test
zig build test-proxy-interop -Dproxy-interop-required=true
sh tools/check-release-tooling.sh
```

Run every public fuzz family in Debug, ReleaseSafe, and ReleaseFast with the
release budget, then run matched Sigbench suites on dedicated machines. A
source checkout is not a supported release until the exact tagged candidate
also passes the kernel/proxy matrix, two-machine regression comparison,
resource plateau, 24-hour soak, archive consumer, signed-tag, checksum, SBOM,
and provenance gates described in [RELEASING.md](RELEASING.md).
