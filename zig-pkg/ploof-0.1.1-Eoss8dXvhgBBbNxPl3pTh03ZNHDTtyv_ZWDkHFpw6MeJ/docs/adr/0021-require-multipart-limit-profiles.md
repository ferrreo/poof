# Require multipart limit profiles

Every multipart route will have a comptime limits profile. The standard profile
allows 16 MiB total, 8 MiB per file, eight parts, four files, 64 KiB per ordinary
field, sixteen header fields and 8 KiB of headers per part, sixteen
`Content-Disposition` parameters, 64 bytes of delimiter transport padding,
128-byte field names,
255-byte filenames, and a 70-byte boundary. No unlimited sentinel will be
provided.

The standard profile is a conservative default, not a server-wide ceiling.
Routes can override individual fields inline while inheriting the rest. The
compiler will reject inconsistent profiles such as a file limit above the total
limit or more files than parts. Since file data streams through fixed chunks,
raising file or total-body byte limits does not reserve matching memory or
require a duplicate global maximum.

Configured size or count violations receive 413; malformed multipart syntax
receives 400. These defaults avoid Gin and Express upload configurations that
can silently spill unbounded data to memory or disk while keeping large-upload
configuration local and obvious.

Disposition parameters have a hard maximum of 64, and delimiter transport
padding has a hard maximum of 1,024 bytes. Configuration above either hard
maximum is rejected at comptime. ADR 0077 and ADR 0084 define their accounting,
failure, and fixed-workspace rules.

Declared part kinds and per-name cardinality follow ADR 0075 and must fit this
profile at route composition.

Part-header syntax and semantics follow ADR 0077.
Decoded client filename limits follow ADR 0078.
Ordinary field buffering follows ADR 0081.
Asynchronous sink-window limits follow ADR 0082.
Boundary syntax, the hard 70-byte maximum, and route-local lower limits follow
ADR 0084.
