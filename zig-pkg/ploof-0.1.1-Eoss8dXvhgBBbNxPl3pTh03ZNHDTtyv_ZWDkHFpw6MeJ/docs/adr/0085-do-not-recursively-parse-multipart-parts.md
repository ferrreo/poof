# Do not recursively parse multipart parts

Ploof version one will not recursively interpret a multipart media type inside
a `multipart/form-data` part. The route's ADR 0075 schema remains authoritative:
a declared `.file` streams the complete part as one opaque file, and a declared
`.bytes_field` receives one bounded opaque value. An inner boundary cannot
create callbacks, alter outer cardinality, or select another limits profile.

A declared text `.field` carrying `multipart/*` receives 415 under ADR 0080's
text media rules. The untrusted part media type remains metadata for opaque
file and byte consumers; it does not activate a parser. An application needing
a legacy nested format must explicitly process the resulting opaque value or
upload outside the standard multipart decoder.

Multiple files for one logical field use repeated outer parts with the same
name and route-declared finite cardinality. RFC 7578 requires that form for
modern senders and deprecates the older nested `multipart/mixed` representation.

This keeps parser depth fixed, preserves one limits and transaction domain, and
matches ordinary Gin and Multer upload workflows. It deliberately does not
implement RFC 7578's recommendation that general-purpose parsers also accept
the deprecated nested representation.

Source: [RFC 7578 section 4.3](https://www.rfc-editor.org/rfc/rfc7578.html#section-4.3).
