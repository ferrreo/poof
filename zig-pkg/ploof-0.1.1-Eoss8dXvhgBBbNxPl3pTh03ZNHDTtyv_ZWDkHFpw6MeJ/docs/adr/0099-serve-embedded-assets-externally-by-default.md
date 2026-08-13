# Serve embedded assets externally by default

Ploof provides a first-party build-time asset declaration for immutable
application files such as CSS and JavaScript. An asset included with
`@embedFile` produces a typed reference and a generated static route, allowing
one executable to serve `<link>` and `<script src>` resources without runtime
filesystem reads. Templates may also contain ordinary literal external asset
tags.

Embedded assets are served as separate HTTP representations by default. This
allows browsers and edge proxies to cache them independently, avoids repeating
their bytes in every HTML response, and supports a strict Content Security
Policy without requiring inline-script or inline-style permission. URL shape,
content hashing, cache fields, precompression, ranges, and validators are
separate decisions.

An HTML template may explicitly inline a build-time CSS or JavaScript asset for
cases such as critical CSS or a small bootstrap script. Inline directives take
only comptime-known application assets, emit no request-dependent values, and
reject an ASCII-case-insensitive `</style` or `</script` sequence for the
matching raw-text element. They are not a raw runtime interpolation escape
hatch. Per-request browser data requires a separate typed representation.

This keeps both deployment modes available while making the cacheable and
Content-Security-Policy-friendly mode the ordinary path. Inline assets trade a
request for larger repeated HTML responses and a more involved CSP policy.
