# Ship confined live static-file routes

Ploof ships first-party `StaticDir` and `StaticFile` route declarations. Their
URL mount paths are comptime route-graph input; each filesystem root is opened
and validated once during startup. These are ordinary routes that inherit their
group and route middleware, including authentication, unlike the deliberately
public embedded-asset routes in ADR 0120.

The declarations use one finite `Limits` profile. Standard maxima are 1 KiB for
the URL mount, 4 KiB each for the filesystem root and selected relative path,
255 bytes for an index name, and 256 bytes for `Cache-Control`; hard maxima are
4 KiB, 4 KiB, 8 KiB, 255 bytes, and 512 bytes respectively. Roots may be
absolute or process-working-directory relative, matching Gin and Express, but
are converted to owned startup descriptors before readiness. The default index
is `index.html`, the default cache policy is `no-cache`, and either is a
comptime value. An index can be disabled explicitly.

Generated routes accept GET and HEAD only and use the normal generated method
semantics. A selected mount owns its path: a missing or disallowed entry returns
404 without falling through to another directory or route. This preserves the
single structural route selection from ADR 0010 rather than adding
filesystem-dependent routing.

After route decoding, Ploof validates a bounded relative file path and resolves
it from the startup root FD with io_uring `openat2`. Resolution uses
`RESOLVE_BENEATH`, `RESOLVE_NO_SYMLINKS`, `RESOLVE_NO_MAGICLINKS`, and
`RESOLVE_NO_XDEV`. Empty, dot, dot-dot, and dot-prefixed components are hidden;
only regular files can become response bodies. Symlinks, mount crossings,
devices, FIFOs, sockets, and directory listings are unavailable in version one.

The pure policy receives both the raw and once-decoded mount suffix. It checks
that they correspond byte for byte under one percent-decoding pass, then checks
both forms. NUL, backslash, malformed escapes, encoded slash or backslash,
empty components, dot, dot-dot, and every dot-prefixed component are rejected.
The terminal slash is structural rather than an empty component. The only
successful output is the decoded relative path without its mount or terminal
slash, plus a bit recording whether that terminal slash was present. No later
layer decodes, cleans, or joins that value as a string.

A root or nested directory request uses `index.html` by default. A finite route
option may replace or disable that name. Opening a directory without its
canonical trailing slash invokes ADR 0011's redirect policy; opening it with
the slash resolves the index relative to that directory FD. Directories without
an allowed index return 404. Ploof never synthesizes an HTML directory listing.

Static files use the versioned extension-to-media-type table from ADR 0050,
fall back to `application/octet-stream`, and send
`X-Content-Type-Options: nosniff`. The mutable-file default is `Cache-Control:
no-cache`, a weak validator derived from the opened file's `statx` identity,
size, and nanosecond modification time, and `Last-Modified`. Standard
preconditions apply to GET and HEAD. A route may declare another finite cache
policy; choosing immutable caching for a mutable filename is then an explicit
application responsibility.

Table version one performs a bounded case-insensitive lookup over common web,
font, image, audio, video, archive, and document extensions. It never sniffs
bytes. The weak validator has the exact form
`W/"dev-major-dev-minor-inode-size-mtime-second-mtime-nanosecond"`, with each
component in lowercase hexadecimal. `Last-Modified` is the IMF-fixdate for the
whole modification second, clamped to `[Unix epoch, response Date]`; the raw
signed second and nanosecond remain in the ETag.
Conditional evaluation applies `If-Match`, otherwise `If-Unmodified-Since`,
then `If-None-Match`, otherwise `If-Modified-Since`. Entity-tag list parsing
retains commas inside opaque quoted tags. A malformed `If-Match` fails the
precondition; malformed other dates or tag lists do not produce a false 304.
The HTTP-date parser accepts IMF-fixdate and both obsolete recipient forms.

Ploof supports one satisfiable byte range, including open-ended and suffix
forms, with `If-Range`, exact `Content-Range`, and 416 for an unsatisfiable
single range. It ignores malformed, unsupported, or multiple ranges and sends
the complete 200 representation. A reversed range is invalid and therefore
ignored. Range is defined only for GET; HEAD ignores it and returns normal
complete-representation metadata without a body.
Multipart byte-range generation remains outside version one.

Internal whitespace, integer overflow, an unknown unit, or more than one member
makes the complete representation win. `If-Range` uses strong entity-tag
comparison. Live static ETags are deliberately weak and filesystem metadata
has no history proving that `Last-Modified` is strong, so neither emitted
validator satisfies `If-Range`; the safe result is a complete 200 transfer.

The opened snapshot is streamed through io_uring and startup-pooled file
buffers with no request heap allocation. Each worker has eight live-transfer
slots by default and one 64 KiB read buffer per slot. Applications can set
`live_static_slots_per_worker` from 1 through 64 and `live_static_read_bytes`
from 4 KiB through 1 MiB; both values are comptime inputs to the worker slab
and io_uring operation inventory. Slot exhaustion returns a bounded 503 rather
than allocating or admitting unbounded work.

Exact read and response bounds come from the opened metadata. Positive short
reads continue until the promised span is complete; zero or oversized reads
fail the connection closed. The terminal body buffer is withheld while one
final `statx` verifies device, inode, type, size, and nanosecond modification
time against the identity used to generate the response head. A failed or
changed identity therefore cannot publish the terminal chunk, including a
same-size in-place mutation. This check does not claim an immutable filesystem
snapshot, but closes the observable whole-transfer mutation window without a
per-chunk syscall. Read failure, cancellation, and disconnect follow the
streaming-response failure contract.

Startup opens every configured root before the worker becomes ready. Startup
failure retains a bounded diagnostic containing root index, path, and io_uring
problem. Drain first cancels and retires request operations and closes every
request descriptor, then closes root descriptors; stopped state requires zero
live-static operations and requests. The application capability manifest adds
`OPENAT2` and `STATX` exactly once and startup rejects a kernel missing either
operation with the normal opcode diagnostic.

The paired `m12-live-static` Sigbench group measures confined path selection,
complete two-stage route preparation, and ranged preparation from identical
case definitions in ReleaseSafe and ReleaseFast. Deterministic reactor tests
cover actual open, stat, read, verification, send, cancellation, and close
schedules; a real io_uring loopback test checks the exact body. The transfer
mechanism remains benchmark-selected rather than promising one Linux zero-copy
opcode in the public API.

Live static files serve only the identity representation in version one. The
edge proxy handles compression and caching where appropriate; small immutable
frontend resources use ADR 0121's build-time asset representations. Opening and
stating each file per request deliberately makes a filesystem change visible on
the next request and avoids an invalidation cache.

Verification includes traversal and encoded-separator corpora, hidden entries,
symlinks and mount crossings, changing and replaced files, index redirects,
media types, preconditions, range forms, short reads, cancellation, pool
exhaustion, and hot-path allocation instrumentation.

Sources: [Gin static-file routes](https://gin-gonic.com/en/docs/rendering/serving-static-files/),
[Express static-file middleware](https://expressjs.com/en/5x/api/express/#express.static),
[`openat2(2)`](https://www.man7.org/linux/man-pages/man2/openat2.2.html), and
[RFC 9110 Range](https://www.rfc-editor.org/rfc/rfc9110.html#name-range-requests).
