# Match Gin path behavior

Ploof version one will match Gin 1.12's default path behavior: valid percent
escapes are decoded before routing, route parameters are decoded, and an
otherwise matching trailing slash redirects with 301 for GET and 307 for other
methods. Paths are not case-corrected, dot segments and repeated slashes are
not cleaned, and malformed percent escapes fail request parsing. Ploof will
retain the raw request target and test encoded separators across supported edge
proxies because decoding `%2F` before routing can create proxy/backend
interpretation differences.

A catch-all includes its leading slash and requires a nonempty remainder:
`/files/*path` matches `/files/` with `path == "/"` and `/files/a` with
`path == "/a"`; `/files` is a trailing-slash redirect candidate. Redirect
lookup uses the requested method, with explicit HEAD checked before its GET
fallback. GET redirects with 301; every other method, including HEAD, uses 307.

`Location` preserves the received origin-form path spelling and query bytes,
apart from adding or removing one terminal literal slash and the same-origin
escape below. Absolute-form requests produce an origin-form location. If the
result would begin with a literal `//`, Ploof percent-encodes the second slash
as `%2F`. Its decoded route path is unchanged, but a browser cannot reinterpret
the location as a network-path reference with a new authority. Raw paths must
also match the request-target URI grammar and decode byte-for-byte to the
selected path; an encoded leading backslash such as `%5C` remains encoded.

If a decoded terminal slash came from `%2F` rather than a literal final slash,
Ploof does not synthesize a removal redirect. A redirect whose location cannot
fit the route response-head profile, including the safety escape, fails before
commitment rather than truncating it.
