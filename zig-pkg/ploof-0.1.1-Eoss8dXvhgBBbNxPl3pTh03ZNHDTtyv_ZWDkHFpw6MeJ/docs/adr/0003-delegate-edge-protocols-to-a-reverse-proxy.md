# Delegate edge protocols to a reverse proxy

Ploof will serve plaintext HTTP/1.1 and rely on a trusted edge proxy for public
TLS and client-facing HTTP/2 or HTTP/3. The boundary is product-neutral: Caddy,
nginx, HAProxy, Envoy, or another conforming reverse proxy may fill the role.
This keeps certificate, TLS, multiplexing, and QUIC complexity outside Ploof's
security-critical core while preserving modern protocols for clients.
This is the version-one boundary and does not preclude native protocol support
later.

Proxy support is first-class. Ploof will retain the direct peer and derive
client address, scheme, and host from standard forwarding metadata only when
the peer belongs to an explicitly trusted proxy range. Untrusted forwarding
metadata will never change canonical request metadata.

Listeners may explicitly enable binary PROXY protocol version 2 for L4 proxy
metadata. Ploof will parse it before HTTP and will never auto-detect it; the
textual version 1 protocol is outside version-one scope.
