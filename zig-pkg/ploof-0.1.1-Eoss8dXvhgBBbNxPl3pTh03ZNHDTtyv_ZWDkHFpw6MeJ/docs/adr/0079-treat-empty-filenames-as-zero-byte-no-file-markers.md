# Treat empty filenames as zero-byte no-file markers

An absent filename on a route-declared file part means a legitimate unnamed
file stream under RFC 7578. An explicitly empty `filename=""` or decoded
`filename*` value instead represents the browser no-file-selected marker.

The empty marker must contain zero part-body bytes. It emits no file-start,
file-chunk, or file-end callbacks and does not consume declared file cardinality
or the file-count limit. It still consumes one part, its header limits, and
total multipart bytes. A required file absent after marker removal fails typed
multipart completion with 400 under ADR 0087.

Any payload byte under an empty filename is contradictory and receives 400;
Ploof does not silently discard hidden content. A non-empty filename with zero
content is a real empty file and emits normal start and end callbacks so a sink
can create it.

Multer also skips a file event whose filename is empty. Ploof distinguishes an
absent filename and rejects non-empty marker content rather than using filename
as the general file classifier.

Sources: [RFC 7578 optional filename](https://www.rfc-editor.org/rfc/rfc7578.html#section-4.2)
and [Multer 2.2.0 upload middleware](https://github.com/expressjs/multer/blob/v2.2.0/lib/make-middleware.js).
