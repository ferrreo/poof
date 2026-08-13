# Use content-addressed public asset routes

Every embedded asset receives a generated public route under a comptime-
replaceable prefix, `/assets/` by default. The remaining path is the first 128
bits of the SHA-256 identity-content digest in lowercase hexadecimal, followed
by one bounded logical name containing lowercase ASCII letters, digits, `.`,
`_`, or `-`. A truncated-digest collision between different full digests,
invalid logical name, or conflict with another route fails at comptime.

The digest and logical name are separate path segments, so the exact default
shape is `/assets/<32-lowercase-hex>/<logical-name>`. A replacement prefix must
begin and end with `/` and contain only nonempty lowercase ASCII route
segments. Logical `.` and `..` names are rejected even though their bytes are
in the character grammar, because browsers and proxies can repair dot
segments before making a request.

There is no unhashed alias or query-string version. A media-typed `AssetRef`
contains the generated identity and is the only template-level reference.
Generated asset routes are public and bypass application authentication;
protected files use ordinary typed application routes instead.

The standard identity response sends `Cache-Control: public,
max-age=31536000, immutable` and a strong ETag derived from the complete wire-
representation digest. It sends no `Last-Modified`, because build time is not
content identity. RFC-compliant `If-None-Match` handling on GET and HEAD returns
304 with the required validator and cache fields. Each future encoded wire
variant has its own strong ETag.

The route prefix and finite freshness lifetime are comptime policy. Changing
asset bytes always changes the URL; Ploof never serves new bytes or redirects
under an old hash. This makes long-lived immutable caching correct but means one
binary serves only its own finite asset bundle.

Rolling deployments must retain old hashed assets at the edge, deploy assets
before HTML, or route asset requests to a version-consistent instance. Ploof
does not silently embed historical bundles or substitute current content for a
missing old identity.

Sources: [RFC 8246 immutable responses][rfc8246],
[RFC 9110 validators and preconditions][rfc9110].

[rfc8246]: https://www.rfc-editor.org/info/rfc8246
[rfc9110]: https://www.rfc-editor.org/rfc/rfc9110.html#name-conditional-requests
