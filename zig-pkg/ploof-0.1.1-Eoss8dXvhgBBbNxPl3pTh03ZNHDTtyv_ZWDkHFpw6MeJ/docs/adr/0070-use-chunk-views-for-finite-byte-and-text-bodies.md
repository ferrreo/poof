# Use chunk views for finite byte and text bodies

The standard finite byte-body decoder returns an immutable, request-scoped
`Body.Bytes` view over worker-owned content-decoded chunks. It exposes total
length, ordered chunk iteration, an optional single-chunk slice fast path,
equality, and copy-to-writer operations. It never exposes HTTP chunk framing or
compressed wire bytes.

Byte and text media-type and charset defaults follow ADR 0071.

`Body.Text` uses the same physical layout after validating the complete decoded
representation as UTF-8 across chunk boundaries. Both views remain valid
through the handler and applicable middleware `response` and `after` phases,
then expire with the request slot.

A route can select an explicit contiguous byte or text decoder variant when a
dependency requires `[]const u8`. The route's finite body limit bounds that
storage, and startup-sized worker pools provide it before handler entry. Ploof
does not silently coalesce a standard chunk view, allocate from a general heap,
or reserve the route maximum for every connection.

Those pools follow the startup-only allocation invariant in ADR 0072.

This differs from Gin's byte slices and Express's buffers on the standard path
to avoid copying or large contiguous reservations. Explicit contiguous mode
retains that familiar shape where compatibility is worth its memory bandwidth
and pool capacity.

Sources: [Gin `GetRawData`](https://github.com/gin-gonic/gin/blob/v1.12.0/context.go)
and [Express `raw`](https://expressjs.com/en/5x/api.html#express.raw).
