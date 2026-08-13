# Return typed responses

Ordinary Ploof handlers return an error union containing a typed Response.
Middleware `head` or `body` phases may return one to short-circuit, while
`response` phases may inspect or transform the result before commitment. A
Response describes its status, headers, and finite body; the runtime will not
commit it to the connection until all applicable `response` phases have run.
Middleware `after` observes the immutable transport outcome. Helpers for JSON,
HTML, text, redirects, files, and empty responses produce this same result
shape.

Streaming uses a separate typed contract because bytes can be committed before
body production completes. It therefore cannot promise that its complete
result remains mutable through completion. ADR 0042 defines its response-trailer
contract, and ADR 0043 defines its middleware boundaries.

A streaming handler returns `Context.StreamResponse(P)`. That value combines a
typed status, media type, and Context-owned header store with one protocol-
neutral `response_stream.Response(P)` body descriptor. `Context.stream` clears
abandoned response headers, preserves the selected route limits, and constructs
the owned result. The descriptor contains exact-or-unknown length, borrowed
trailer declarations, and one concrete producer value; it does not describe an
HTTP version or response head.

Application composition copies the safely relocatable producer in place into
the aligned request Workspace and generates its erased callbacks at comptime;
it never retains a handler-stack pointer, creates a workspace-sized temporary,
or allocates a producer. Self-relative producer pointers are unsupported. The
runtime gives the producer a bounded output slice and accepts exactly three
results: nonempty progress, completion, or pending. Empty progress is an
invariant failure. The poll failure type is the fixed
`response_stream.PollError`, never `anyerror`.
The output is borrowed only for that poll: the producer initializes every byte
in the reported progress prefix and neither retains nor mutates the slice after
returning. Completed trailer descriptors, names, and values remain immutable
and race-free until producer join.

Pending is an explicit asynchronous state, not polling. Each poll receives a
copyable generation-scoped public `response_stream.Wake`, backed by the
runtime's `StreamWake`. A producer returning pending may call that handle from
another thread; an atomic pending bit and the worker wake
event prevent a wake racing the return from being lost. A handle is one-shot
for one request generation, and stale calls are ignored and counted. The
runtime never polls again while a prior output slice is queued for SEND.
On cancellation or failure the runtime invalidates wake ownership, calls an
optional `abort(*P) void` at most once, and then calls an optional
`join(*P) void` at most once. Normal completion joins without aborting. Missing
lifecycle methods erase to direct comptime no-ops. Only after join proves that
publishers have stopped may the runtime clear borrowed declarations, securely
zero producer storage, run `after`, and release the Workspace.

Every committed stream buffer contributes to a request-local response-staging
high-water mark. Release securely clears that maximum rather than only the
last, usually smaller, terminal buffer. An uncommitted writable buffer remains
fully dirty across a later terminal or progress commit and therefore causes a
full-region clear. This prevents an earlier large chunk, or bytes written by a
poll that returns pending or done, from surviving slot reuse after a small
terminal chunk or a later send failure.

`StreamWake` uses a nonwrapping external generation rather than the reactor's
wrapping 16-bit operation generation. A stream-enabled worker owns one
stream-only eventfd and one one-shot poll controller; duplicate ready bits
coalesce, while wake publication on an empty inventory signals the descriptor.
A two-level nonempty-word bitmap lets the worker snapshot and dispatch only
ready leaves; its worker-owned batch remains stable through callback dispatch.
The descriptor remains open until shutdown has invalidated every handle and
joined every producer that can publish. Request-gzip uses an independent wake
source so neither subsystem can drain or close a descriptor still owned by the
other. Finite-only application graphs carry neither stream wake state nor its
kernel operation.

Version one streams identity bytes only. It sends 406 when identity is forbidden
by `Accept-Encoding` and merges `Vary: Accept-Encoding` when identity is
accepted. Automatic gzip fully stages finite responses under ADR 0114; it does
not buffer a stream merely to make it compressible. A later streaming content
coder can extend the producer chain without changing the handler result shape.

The stream length is an application contract, not HTTP/1.1 framing. HTTP/1.1
maps exact length to `Content-Length` and unknown length to chunked transfer;
later HTTP/2 and HTTP/3 transports map the same descriptor to DATA and end-
stream semantics without changing handlers.

A fully transmitted unknown-stream terminal buffer and a fully transmitted
suppressed HEAD head are complete responses. If their SEND CQE races an earlier
timeout or shutdown request, successful full-buffer completion wins, matching
finite-response behavior. A head or body buffer is not terminal: cancellation
keeps the first transport failure, invalidates the wake, aborts where needed,
and joins without polling or queueing another buffer.

This replaces Gin and Express's implicit mutable response-writer contract with
explicit Zig control flow. It prevents forgotten responses, lets middleware
inspect or adjust completed results, and permits response staging in worker-
owned fixed-capacity memory rather than per-request heap allocations.

An application Context fixes a response-workspace profile at comptime. Routes
may select smaller logical response-head profiles, and composition rejects any
route profile larger than that workspace. Dynamic header mutation observes the
selected route limit even though storage comes from the shared maximum-sized
workspace.

Generated slash redirects for a matched method use that route's logical
response-head profile. Server-wide OPTIONS and unmatched method results use the
application profile because they do not select one route.

Version one's base finite body reference is either empty, comptime-static,
copied into fixed Context-owned response-body storage, or explicitly borrowed
from application or request-workspace storage that remains valid through
transmission and `after`. `Context.text`, `Context.textFormat`, and
`Context.bytes` are the safe dynamic constructors. Their per-application
capacity defaults to 16 KiB, can be disabled, and has a 16 MiB hard bound.
Names ending in `Borrowed` make the immutable-through-serialization lifetime
contract explicit. Ploof never treats handler stack memory as asynchronously
owned.

Constructing a new Response clears prior application headers in its selected
response workspace while preserving that workspace's logical limits. This
makes short-circuits and mapped replacements independent of abandoned
responses. The application boundary rejects foreign response-header storage
and invalid status, media, or body combinations before response middleware can
observe them, replacing them with the safe generic 500 response.
