# Do not silently skip declared upload files

A file-start acceptance policy has two outcomes: accept the declared file or
reject the request with a typed Response or application failure. It cannot mark
a schema-known file as skipped while allowing the request to complete. The
`claimedMediaTypes` helper from ADR 0090 uses 415 for its standard rejection.

Rejection stops body intake, aborts every earlier staged sink under ADR 0083,
and closes the connection when unread body bytes remain. The rejected file does
not begin a sink or satisfy multipart cardinality because the request itself no
longer has a successful body result.

An application that intentionally accepts and disposes of a declared file uses
an explicit concrete discard sink or wrapper sink. That file still consumes all
limits and cardinality and remains visible in the route schema. Opt-in discard
of unknown part names remains the separate ADR 0076 policy.

Multer's `fileFilter` can return false to consume a file without placing it in
`req.file` or `req.files`. Ploof deliberately rejects that silent shape change.
It preserves the distinction between a file the client did not submit and one
the application's policy refused, and prevents a nominally successful request
from hiding unwanted upload bandwidth.

Source: [Multer `fileFilter`](https://expressjs.com/en/resources/middleware/multer/#filefilter).
