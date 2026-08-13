# Start with HTTP/1.1

Ploof version one will implement plaintext HTTP/1.1 only. Application-facing
request, response, routing, and handler semantics will not expose wire-protocol
details, while HTTP/1.1 parsing and framing stay behind one internal protocol
boundary. This keeps version one small and auditable without blocking later
native TLS, HTTP/2, or HTTP/3-over-QUIC support; we will not build those unused
engines or a public protocol plugin system in advance.
