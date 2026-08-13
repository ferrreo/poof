# Bound bodies and stream uploads

Ordinary JSON, URL-encoded form, and raw request bodies will be accumulated in
worker-owned, preallocated chunks before their handler runs. Each route will
have a compile-time body limit, defaulting to 1 MiB; the limit is not a per-
connection reservation. A declared `Content-Length` over the limit or a body
that crosses it will receive 413.

Finite byte and text body views follow ADR 0070; storage is not implicitly
coalesced.

All framework body storage is acquired from startup-created workspaces under
ADR 0072; request handling does not invoke a general allocator.

URL-encoded body fields remain separate from URI query fields under ADR 0060.
Their flat decoding grammar and field-count limit follow ADR 0061.

Version one will also support request decompression, response compression, and
streaming multipart file uploads. Content codings will run incrementally with
independent encoded-wire and decoded byte limits. The encoded-wire count starts
after the request head and includes HTTP chunk framing as defined by ADR 0040.
Multipart processing will bound part count, part-header bytes, disposition
parameter count, delimiter-padding bytes, field bytes, file bytes, and total
body bytes, and will not retain a complete file in memory. The supported content
codings and upload-stream ownership contract are separate decisions.
