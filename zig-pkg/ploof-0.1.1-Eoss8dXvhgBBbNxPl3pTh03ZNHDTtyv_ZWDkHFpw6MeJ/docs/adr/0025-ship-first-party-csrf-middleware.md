# Ship first-party CSRF middleware

Ploof version one will ship first-party CSRF middleware that applications apply
explicitly to cookie-authenticated applications or route groups. It will
protect every method except GET, HEAD, and OPTIONS; TRACE remains unsupported,
and unknown or custom methods are treated as unsafe.

The middleware `head` phase evaluates Fetch Metadata and compares Origin, then
Referer origin, against configured CSRF source origins. Duplicate physical
Fetch Metadata fields fail closed. Unknown or syntactically invalid
`Sec-Fetch-Site` values are ignored for forward compatibility and the remaining
origin and token checks still run. A present Origin or Referer must parse and
match exactly. An exact configured match may authorize a deliberately trusted
cross-site frontend; cross-site metadata without either source header fails.
These checks run before 100 Continue but remain defense in depth rather than a
replacement for a token. Missing metadata can proceed to token validation.
Effective request scheme and authority must match a canonical public origin.
The optional CSRF source-origin set defaults to the public-origin set but
replaces it when provided. The two checks are never combined into one widened
deployment boundary, and every allowed cross-site request still needs a valid
token.

Tokens may arrive in `X-CSRF-Token`, a URL-encoded form field, or a multipart
field. Duplicate physical fields, repeated values, and multiple token sources
are rejected even when their bytes match. Query values are never inspected.
Comparison is constant-time after strict fixed-length canonical decoding.

Middleware order follows the same outer-to-inner model familiar from Gin and
Express. Session or authentication middleware with only a head phase may run
before CSRF, but CSRF must precede every middleware that declares a body phase.
Ploof rejects an unsafe chain at compile time and tells the application to move
CSRF earlier or split its head and body concerns.

Multipart forms must place the token field before any file part; the HTML
template helper emits that order. Ploof invokes no application `fileStart`,
sink `begin`, or sink write before one valid header or earlier multipart token.
A file before the token is rejected before admission. A later duplicate token
aborts every conforming staged sink and prevents commit. Ploof cannot prove
that arbitrary custom sink or application callback code avoided irreversible
side effects, so it does not claim that already received kernel bytes can be
undone or that dishonest extensions are transactional.

Header-determined failures receive their final response without 100 Continue.
Form and multipart validation is body-dependent and may therefore receive 100,
but multipart file admission remains gated. Failures receive a fixed empty 403
response with `Cache-Control: no-store`; an effective public origin outside the
configured set receives a fixed 421. Tokens are never echoed, placed in URLs,
or emitted by first-party logging. Token-bearing responses receive
`Cache-Control: no-store, no-transform`, disabling Ploof response compression.
SameSite cookies remain a defense-in-depth setting, not the sole control.
Bearer-only APIs and webhook routes can select different explicit middleware
policies.

The token construction, session binding, key lifecycle, and exact public-origin
configuration are separate decisions.
