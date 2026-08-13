# Use explicit listener forwarding profiles

Each Ploof listener will have an explicit forwarding profile. It preserves the
actual transport peer and separately derives a client address only after
checking the peer against a startup-parsed exact-address and CIDR trust set.
Ploof will not offer a global boolean equivalent to Express's `trust proxy`.
IPv6 link-local addresses are never trusted, including through `::/0`, because
an unscoped address cannot identify the accepting interface.

PROXY protocol is independently either disabled or v2-required, retaining ADR
0003's rule that it is never sniffed. HTTP forwarding metadata is independently
disabled or selects exactly one of RFC Forwarded and the X-Forwarded family.
Competing families are never merged. The default maximum chain is eight hops
and can be changed at comptime.

Address chains are evaluated from the nearest hop outward and stop at the first
untrusted address. Forwarded HTTP metadata from an untrusted direct peer is
ignored on a listener that also permits direct traffic; a proxy-only listener
rejects that peer. Duplicate, contradictory, malformed, or over-limit trusted
HTTP metadata receives 400 and closes the connection. Malformed required PROXY
v2 framing closes before HTTP parsing.

When a trusted transport supplies PROXY v2, its source address starts HTTP
client-chain walking but does not revoke the transport's authority to supply the
selected forwarded host and scheme. A public source therefore stops older
client-address claims while trusted host and scheme metadata still apply. Ploof
retains the PROXY destination internally for diagnostics without treating it as
request authority.

Forwarded scheme and host values remain request metadata and may select, but
never create or widen, canonical public origins or CORS allowlists. The request
API exposes transport peer, resolved client address, and provenance as distinct
typed values.
