# Discard unsupported multipart part headers

The standard multipart API retains only the decoded `Content-Disposition`
name and optional client filename plus the optional parsed `Content-Type`.
`Content-Transfer-Encoding` remains a request error under ADR 0077. Every other
syntactically valid part header is validated and counted against the part-header
limits, then discarded without occupying request workspace or reaching an
application callback. Unknown `Content-Disposition` parameters similarly count
against ADR 0077's separate parameter limit before being discarded.

Applications carry structured upload metadata in declared multipart fields or
top-level request headers. Ploof version one provides no generic part-header
map, ordered part-header list, or route escape hatch for custom headers.

This follows RFC 7578's requirement to ignore unsupported part headers and
matches the ordinary Multer workflow. It deliberately exposes less than Go's
low-level `multipart.Part.Header`. Custom per-part `Content-ID`, checksum, and
extension-header workflows must use explicit form fields or wait for a measured
typed requirement.

Discarding unsupported fields avoids retaining client-controlled names and
values that have no framework semantics while preserving strict syntax and
resource accounting.

Source: [RFC 7578 section 4.8](https://www.rfc-editor.org/rfc/rfc7578.html#section-4.8).
