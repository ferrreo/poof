# Separate file media claims from content verification

Each declared file can attach one concrete comptime acceptance policy that runs
after its part headers validate but before sink creation or file-byte delivery.
The policy receives typed file-start metadata, including the optional parsed
part `Content-Type`. Missing file media metadata remains absent rather than
being guessed from a filename or replaced with a default.

Ploof ships an allocation-free `claimedMediaTypes` policy helper. It compares
the normalized media type and subtype against a comptime exact list, has an
explicit missing-value rule, and rejects a mismatch with 415. Its name, types,
and documentation call the value a client claim rather than verified content.
Parameters remain untrusted metadata and do not select another parser or sink.

Ploof never infers a file type from its client filename and performs no generic
automatic byte sniffing. A route that needs actual format validation composes a
concrete streaming verifier with its sink. That verifier can retain a bounded
prefix in fixed sink state, inspect later chunks, or run a format-specific
decoder, and any failure prevents ADR 0083 transaction commit.

This separates a cheap interoperability filter from a security assertion.
Generic sniffing recognizes only some formats, adds buffering to routes that do
not need it, and cannot establish that active or polyglot content is safe for an
application's eventual use.

The acceptance hook is the typed Ploof equivalent of Multer's `fileFilter`;
Gin leaves both header checks and byte validation to application code. Ploof's
built-in helper improves common-case ergonomics without presenting a claimed
MIME value as proof.

Acceptance policies reject rather than silently skip a declared file under ADR
0091.

Sources: [Gin upload handling](https://github.com/gin-gonic/gin/blob/v1.12.0/context.go),
[Multer file filtering](https://github.com/expressjs/multer/blob/v2.2.0/lib/make-middleware.js),
and [Busboy multipart metadata](https://github.com/mscdex/busboy/blob/v1.6.0/lib/types/multipart.js).
