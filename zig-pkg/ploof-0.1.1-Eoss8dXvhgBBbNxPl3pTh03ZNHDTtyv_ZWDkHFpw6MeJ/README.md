# Ploof

Ploof is a typed HTTP application framework for Zig 0.16.0. It targets the
same application-building role as Gin and Express while using a closed comptime
route graph, fixed startup-owned memory, and a custom libc-free io_uring
runtime.

Version 0.1 serves plaintext HTTP/1.1 on Linux x86_64-v3. Put a trusted reverse
proxy such as Caddy, nginx, HAProxy, or Envoy in front for TLS and client-facing
HTTP/2 or HTTP/3. Ploof does not link libc, liburing, OpenSSL, or zlib. Required
io_uring capabilities are checked actively at startup; a missing capability is
a bounded startup error and never selects a fallback reactor.

The feature surface through M13 and M14's release-evidence machinery is
present. Each release requires one immutable candidate to pass M14's
minimum-kernel/CPU matrix, two-machine performance, fuzz-budget, 24-hour soak,
signed-tag, and provenance evidence. An unreleased checkout has no
security-support claim.

## What is included

- Gin-like method/path routing, groups, path parameters, middleware phases,
  typed application state, and central typed error mapping.
- Strict HTTP/1.1 parsing and framing with request-smuggling defenses,
  keep-alive, pipelining, chunked bodies and trailers, `100 Continue`, finite
  and streaming responses, and graceful two-stage shutdown.
- Bounded query, form, typed and dynamic JSON, byte, text, gzip request, and
  gzip response support.
- Streaming multipart parsing, configurable 16 MiB default multipart limits,
  custom typed sinks, and a confined transactional filesystem `FileSink`.
- Explicit CORS modes, including wildcard allow, and synchronizer or signed
  CSRF policies whose request state spans head and body phases.
- Build-time typed HTML templates, layouts, partials, contextual escaping,
  typed URLs, safe browser JSON, embedded CSS/JavaScript and other assets, plus
  confined live static files.
- Trusted `Forwarded`, `X-Forwarded-*`, and explicit PROXY protocol v2
  handling. Untrusted forwarding fields never rewrite request identity.
- Fixed-cardinality metrics, OpenMetrics exposition, health handlers, and
  bounded zero-allocation access logging.

Framework request processing performs no heap allocation after readiness.
Capacity, route, decoder, upload, template, asset, logging, and observability
storage is fixed at build or startup time. Application code and custom sinks
remain responsible for their own allocation behavior.

Route graph construction and lookup are bounded separately from route count.
`graph_limits` can raise or lower aggregate segments, aggregate pattern bytes,
index nodes, search visits, and compared bytes at comptime. The generated
application exposes exact index, search-workspace, visit, and comparison sizes;
each worker reserves its search workspace before readiness.

## Minimal application

```zig
const ploof = @import("ploof");

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);

fn ping(context: *Context) Context.ResponseType {
    return context.textStatic(.ok, "pong");
}

const App = ploof.Application(.{
    .State = State,
    .routes = .{ploof.get("/ping", ping)},
});
const Runner = ploof.ServerRunner(App, .{ .workers_max = 4 });

// Server and Runner values must retain their address and explicit type
// alignment from startup through shutdown.
var runner: Runner align(@alignOf(Runner)) = Runner.init();

pub fn main() void {
    var state = State{};
    runner.runOrExit(&state, .{
        .listener = .{ .address = .{ .ipv4 = .{
            .bytes = .{ 127, 0, 0, 1 },
            .port = 8080,
        } } },
        .worker_count = 4,
    });
}
```

`runOrExit` consumes SIGTERM and SIGINT through `signalfd`, drains, and writes a
bounded diagnostic on startup or shutdown failure. Applications needing their
own process-control policy can own `ploof.Server` directly.

`context.text` and `context.bytes` copy dynamic values into request-owned fixed
storage; `context.textFormat` formats there directly. The standard capacity is
16 KiB and can be selected per application from zero through 16 MiB with
`.response_body_bytes_max`. Static helpers remain zero-copy. APIs ending in
`Borrowed` are advanced escape hatches whose input must remain immutable and
live until response serialization completes.

When a reverse proxy supplies client identity, configure the listener trust
boundary explicitly. For example, a local nginx or Caddy instance using
`X-Forwarded-*` requires `.family = .x_forwarded` and a trusted peer such as
`127.0.0.1`; forwarding fields from every other peer are ignored. PROXY v2 is
opt-in and required when selected, never auto-detected.

## Requirements

- Zig 0.16.0 exactly.
- Linux x86_64 with the x86-64-v3 feature set.
- Linux 6.1 or newer and Ploof's required io_uring features and operations.
- ReleaseSafe for supported production builds. ReleaseFast is a measured
  diagnostic build, not the production recommendation.

## Verification

Run the full local correctness matrix, including Debug, ReleaseSafe,
ReleaseFast, real io_uring integration, package consumers, compile failures,
allocation checks, and ThreadSanitizer:

```sh
zig build test
```

Run direct, Caddy, nginx, forwarding, and PROXY v2 interoperability:

```sh
zig build test-proxy-interop -Dproxy-interop-required=true
```

Every public fuzz family has Debug, ReleaseSafe, and ReleaseFast steps driven
through Ploof's fail-closed native-fuzz wrapper. List exact targets with
`zig build --help`; set generated work with `-Dfuzz-runs`:

```sh
zig build fuzz-http1 -Dfuzz-runs=1000000
zig build fuzz-http1-release-safe -Dfuzz-runs=1000000
zig build fuzz-http1-release-fast -Dfuzz-runs=1000000
```

Run matched Sigbench 0.0.5 suites only when the lazy benchmark dependency is
explicitly enabled:

```sh
zig build -Dbenchmarks=true bench-release-safe
zig build -Dbenchmarks=true bench-release-fast
```

See [project language and contracts](CONTEXT.md), the
[implementation plan](docs/IMPLEMENTATION_PLAN.md),
[deployment and operations guide](docs/DEPLOYMENT.md),
[embedded asset guide](docs/ASSETS.md),
[HTTP/1.1 load-driver guide](docs/LOAD_DRIVER.md),
[release procedure](docs/RELEASING.md), and
[architecture decisions](docs/adr/).
