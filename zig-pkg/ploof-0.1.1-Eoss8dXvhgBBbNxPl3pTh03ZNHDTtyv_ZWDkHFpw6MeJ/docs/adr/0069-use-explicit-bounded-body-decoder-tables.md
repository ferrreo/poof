# Use explicit bounded body decoder tables

Every route that consumes a request body declares a comptime table of one to
four body decoders. Each decoder declares its accepted media types. JSON covers
`application/json` and `application/*+json`; URL-encoded form covers exactly
`application/x-www-form-urlencoded` with ADR 0066's charset rule. Route
composition rejects overlapping media patterns.

The runtime parses `Content-Type` once during the request-head phase and
dispatches directly through generated route code. A route with alternatives
receives a tagged union that preserves which decoder produced the value. Ploof
does not select a decoder from the HTTP method, global middleware order, body
bytes, or a failed previous decoder, and never parses the same body speculatively
under multiple formats.

A missing or unsupported media type receives 415, including for an empty body.
A malformed or duplicate `Content-Type` field receives 400. Media type and
subtype matching is ASCII case-insensitive; parameters do not choose another
decoder. Syntax or conversion failure after a supported decoder is selected
receives that decoder's normal 400 or 413 result; it never falls through to
another representation. Selection occurs before `100 Continue`, allowing
rejection without receiving the body.

Multipart streaming remains an explicitly declared decoder with its own body
lifecycle, never a fallback. The four-alternative ceiling bounds generated code
and per-route metadata while covering the version-one buffered, raw, and
streaming representations.

Finite byte and text decoder media rules follow ADR 0071.

This retains the ability to accept several formats found in Gin and Express but
makes the accepted set, result type, and dispatch cost visible at route
composition.

Sources: [Gin 1.12 binding selection](https://github.com/gin-gonic/gin/blob/v1.12.0/binding/binding.go#L93-L119)
and [Express body parsers](https://expressjs.com/en/5x/api.html#express.json).
