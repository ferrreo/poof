# Proxy interoperability fixtures

These fixtures prove TLS-to-HTTP/1.1 forwarding with stock Caddy and nginx.
Caddy also proves upstream PROXY protocol v2. Stock nginx only emits upstream
PROXY protocol v1 from its stream module, so its HTTP profile exercises the
selected X-Forwarded family instead.

Each of the 12 mode/topology runs sends 15 hostile-header cases. The matrix
also covers a gzip request and response, a 32 KiB streamed response, and a
chunked multipart upload containing one deterministic 64 KiB file. Direct
cases retain an absolute request target. Encoded slash, backslash, unreserved,
dot-segment, and double-escape cases prove that raw and decoded path behavior
stays identical through direct, Caddy, nginx, and PROXY v2 topologies.

`interop.key` is intentionally public and must never be used outside tests.
The committed certificate is trusted explicitly by the test client; hostname
verification remains enabled for `interop.test`.

Pinned linux/amd64 images:

- `caddy:2.11.4-alpine@sha256:98eb57d882ccd5213d1688764db10c1ca2c58a1ca3a6717a3411ad798f7a423a`
- `nginx:1.30.4-alpine@sha256:8a4f4b94275ff59d809477799cbbaf1a7ab65ed1871403d05e31fd66bdb8db82`
