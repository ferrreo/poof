# Serve build-time embedded asset representations

Every embedded asset includes its identity representation. Ploof's build
helper also produces and embeds one deterministic gzip representation for
media types and sizes classified as compressible by the versioned asset table.
Already-compressed formats remain identity-only. Compressor parameters are
fixed for one build, and volatile gzip metadata is normalized so identical
inputs and build policy produce identical wire bytes.

Version one's asset-media table precompresses declared CSS, JavaScript, JSON,
SVG, plain text, HTML, and XML from 1 KiB through 4 MiB inclusive. It uses Zig
0.16's standard-library best compression level and normalizes the gzip
modification time to zero and OS byte to 255. Declared images, fonts, Wasm,
and generic binary assets remain identity-only. These thresholds and media
classifications are part of generated-module format version one.

Generated routes accept GET and HEAD only. They send the asset's declared media
type and `X-Content-Type-Options: nosniff`; Ploof never infers a type from the
bytes. Normal `Accept-Encoding` negotiation from ADR 0019 selects identity or
the prebuilt gzip representation and emits `Vary: Accept-Encoding`. Each
selected representation uses its own full-wire-digest strong ETag under ADR
0120. HEAD selects the same representation and fields as GET while suppressing
the body.

Asset delivery performs no request-time compression, allocation, or gzip
workspace acquisition. It does not use the general finite-response compressor
from ADR 0114. Brotli remains outside version one.

Version one ignores Range on generated embedded-asset routes and sends the
complete selected representation. Large media requiring seeking belongs at the
edge, in object storage, or on the separately designed general static-file
path; this specialization keeps small immutable frontend assets allocation-free.

An `AssetRef` renders the local content-addressed path by default. At startup,
the application may instead select one trusted HTTPS origin with an optional
fixed path prefix, validated under the same application-input boundary as ADR
0104. Request headers and request data cannot influence this asset origin. The
local generated routes remain present as the bundle's canonical fallback, and
an external origin must publish and retain the exact same hashed paths and wire
representations.

Verification covers deterministic build output, identity and gzip negotiation,
wildcards and quality weights, variant ETags and conditional HEAD/GET, declared
media types, ignored ranges, allocation-free delivery, and local and external
asset origins.

Source: [RFC 9110 representation metadata, content negotiation, and Range][rfc9110].

[rfc9110]: https://www.rfc-editor.org/rfc/rfc9110.html
