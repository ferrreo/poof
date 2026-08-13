# HTTP/1.1 load driver

`zig build load-driver` builds the libc-free `ploof-load-driver` artifact.
`zig build test-load-driver` runs unit and production-loopback checks in Debug,
ReleaseSafe, and ReleaseFast. A default `zig build` installs the ReleaseSafe
x86_64-v3 binary at `zig-out/bin/ploof-load-driver`.

The driver owns fixed global storage. It allocates no memory after process
entry. One `ppoll` event loop drives at most 256 nonblocking connections. Each
connection owns its response head, incremental SHA-256 state, and receive
buffer. Request heads, a file-backed body of at most 1 MiB, generated-body
scratch, 65 log2 latency buckets, and the 16 KiB JSON report are bounded
upfront. Inline request bodies are limited to 8 KiB, generated bodies to
16 MiB, inline expected bodies to 128 KiB, and length-plus-SHA-256 expected
bodies to 1 GiB. The CLI rejects more than eight custom headers, names over 64
bytes, values over 512 bytes, and attempts to override `Host`, `Content-Length`,
`Transfer-Encoding`, `Connection`, or `Content-Type`.

Closed-loop mode issues the next request when a connection becomes idle.
Constant-rate mode derives every scheduled timestamp from request ordinal and
configured rate. Latency starts at that timestamp, not at eventual socket
write, so queue delay remains visible and completion gating cannot hide
overload. Reports count late starts and requests whose schedule-to-timeout
window expired before a connection became available.

Example:

```sh
zig-out/bin/ploof-load-driver \
  --address 127.0.0.1 --host app.test --port 8080 --path /api/items \
  --requests 100000 --concurrency 64 \
  --scheduling constant-rate --rate 50000 --connections keepalive \
  --header 'Accept-Encoding: gzip' \
  --expect-status 200 --expect-body-bytes 4096 \
  --expect-sha256 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
```

`--request-body-file` reads one body into fixed storage before measurement.
`--request-body-bytes N --request-body-byte HEX` synthesizes a repeated byte
without storing `N` bytes. These modes cover multipart fixtures, compressed
request fixtures, and large identity bodies. Expected responses use either
exact inline bytes or exact length plus incremental SHA-256, including chunked
and close-delimited HTTP/1.1 bodies.

One JSON document records driver/schema/build mode, complete target and ordered
header configuration, body source modes and digests, throughput, wire bytes,
transport/status/parser/identity failures, late and missed starts, all log2
histogram buckets, and p50/p95/p99/p99.9 upper bounds. Custom header values are
retained verbatim; benchmark commands must not contain credentials.

Calibration is deliberately narrower than a deployment benchmark:

```sh
zig-out/bin/ploof-load-driver --scheduling constant-rate --rate 50000 \
  --requests 1000000 --calibrate
```

It measures the scheduler/request-byte loop without sockets or a server and
fails below twice the selected offered rate. Its report is labelled
`scheduler-request-loop-lower-bound`. Deployment evidence still needs the
separate physical client/server run required by ADR 0128.

Version one accepts numeric IPv4 connect addresses only. `--host` remains the
independent HTTP authority for virtual hosts and proxies. DNS, IPv6, request
pipelining, `HEAD`, `CONNECT`, and expected status 304 are rejected explicitly.
