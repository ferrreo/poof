# Ploof

Ploof is a cohesive HTTP application framework intended to replace Gin and
Express for Zig applications: applications use one product to receive
requests, select behavior, and produce responses.

## Language

**Ploof application**:
An HTTP application built with Ploof as the complete framework between an
incoming request and its outgoing response.
_Avoid_: Ploof server engine, networking toolkit

**Replacement target**:
A framework whose users should find Ploof easy to adopt when building the same
kind of service in Zig. Gin and Express are replacement targets: Ploof keeps
their useful concepts and workflows recognizable while using idiomatic,
strongly typed Zig. This is a familiarity goal, not source or behavioral
compatibility across languages.
_Avoid_: Benchmark opponent, API clone

**Comparison baseline**:
The current stable Gin/Go and Express/Node behavior used to challenge Ploof's
public defaults and workflows. Ploof may diverge for safety, measured
performance, or Zig semantics, but a divergence must be deliberate and visible.
_Avoid_: Compatibility contract, parity target

**Public API**:
The documented source declarations intentionally re-exported by the `ploof` or
`ploof_testing` package module, the `ploof-assets` build artifact contract, and
documented observable defaults. Internal paths, layouts, and symbols are not
included merely because their source is present in the package.
_Avoid_: Repository source tree, binary ABI

**Application state**:
The caller-owned concrete typed value supplied at startup and explicitly made
available to handlers and middleware. Ploof neither constructs a string-keyed
service container nor supplies synchronization for shared mutable fields.
_Avoid_: App locals, dependency registry

**Application context**:
The typed request-local view passed explicitly to handlers and middleware. It
borrows application state, admitted request metadata, route parameters, and one
preallocated response workspace; it is not a string-keyed value bag.
_Avoid_: Global request, dynamic context map

**Admitted application input**:
The bounded request view constructed only after HTTP syntax, target, framing,
query, and request-admission checks succeed. It preserves raw target components
beside the decoded route path and is the boundary at which application
middleware may begin.
_Avoid_: Raw socket bytes, partially parsed request

**Prepared application response**:
Serialized response bytes whose request Context and initialized middleware
state remain owned by one pending Workspace until transport calls `complete`
or `abort`. Preparation is not evidence that bytes reached the peer.
_Avoid_: Completed response, reusable request slot

**Reactor capability manifest**:
The finite comptime set of io_uring flags, features, registrations, operations,
and active checks required by the HTTP runtime and the application's declared
route features. It determines startup admission without exposing io_uring to
application code.
_Avoid_: Kernel-version assumption, opportunistic fallback

**Startup failure**:
A bounded typed explanation of why no listener became ready. It identifies the
failed initialization phase and relevant deployment facts without starting a
reduced-capability server. It also identifies cleanup whose descriptor ownership
could not be proven and therefore requires the caller to terminate the process;
the `require` convenience entry point always exits on failure.
_Avoid_: Startup panic, fallback warning

**Deterministic test reactor**:
A test-only completion source beneath Ploof's private normalized reactor seam.
It drives the production connection, request, middleware, body, response, file,
logging, and shutdown state machines with virtual time and injected outcomes.
It is neither a second HTTP implementation nor a production io_uring fallback.
_Avoid_: Mock server, portable runtime backend

**Failure trace**:
The replayable seed and bounded ordered event record for one deterministic test
failure. It identifies completion ordering, injected outcomes, and virtual-time
advances without retaining request secrets.
_Avoid_: Flaky-test log, packet capture

**Fuzz target**:
A deterministic adapter from generated structured values or raw bytes into one
production parser, serializer, compiler, or runtime state machine plus explicit
bounded security oracles. The same adapter replays ordinary regression corpus
entries without requiring a fuzzing engine.
_Avoid_: Random integration test, fuzzer-only implementation

**Security corpus**:
The versioned minimal set of public protocol inputs that previously exposed a
failure or materially extends an attack boundary. Each entry has a deterministic
oracle and contains no captured private request data.
_Avoid_: Traffic archive, unreproducible crash dump

**Libc-free production fixture**:
A standalone Ploof application built without linking libc or liburing and
inspected for unexpected dynamic dependencies or unresolved C symbols. It
proves that Ploof uses Zig's Linux syscall surface directly; it does not prevent
an application from linking libc for its own unrelated dependencies.
_Avoid_: Musl build, restriction on application dependencies

**Certified support matrix**:
The versioned assignment of the exact Zig compiler, Debug, ReleaseSafe, and
ReleaseFast checks, x86_64-v3 CPU vendors, active upstream kernel lines, real
and simulated I/O suites, and Caddy and nginx deployment profiles required for a release.
Runtime capability admission remains authoritative beyond those certified
combinations.
_Avoid_: Kernel-version promise, libc matrix

**Trusted CI lane**:
Tests that require real kernels, privileged instrumentation, proxies, or stable
performance hardware and therefore run only after source is trusted on
ephemeral isolated workers. Unreviewed fork code never receives credentials or
runs on permanent benchmark hosts.
_Avoid_: General pull-request runner, shared shell host

**Release evidence**:
The retained test, fuzz, sanitizer, soak, performance, package, checksum, and
provenance results for the exact tagged source revision. A skipped, flaky, or
incompatible required result is missing evidence rather than a passing release.
_Avoid_: Green badge, manually asserted readiness

**External evidence contract**:
The versioned fail-closed profile in `release/gates.json` and the canonical
semantic manifest at the root of one retained external-evidence archive. It
binds candidate and baseline revisions, modes, case identities, workloads,
topology, tools, host roles, physical-machine separation, exact work budgets,
and measurement intervals before retained output can become **release
evidence**.
_Avoid_: Opaque test tar, successful external command

**Physical machine identity**:
A stable privacy-preserving hash of the recorder's machine identity, paired
with the protected runner inventory's assertion that the host is physical.
Deployment evidence uses distinct client and server identities. The hash
detects reuse of one recorded OS identity; by itself it cannot prove hardware
separation, so runner labels, hostnames, containers, and virtual-machine names
are not substitutes for controlled physical-host inventory.
_Avoid_: Cryptographic hardware attestation, runner name, topology assertion

**Security-supported line**:
A Ploof minor line eligible for coordinated vulnerability fixes. Before 1.0,
the newest minor receives all fixes and the immediately preceding minor
receives high and critical security fixes for 90 days after its successor.
_Avoid_: Indefinite pre-1.0 maintenance, every historical patch

**Consumer fixture**:
A standalone Zig application that fetches a released Ploof archive and builds
using only its documented package modules and artifacts. It proves the package
boundary rather than importing the repository checkout directly.
_Avoid_: Internal example, source-path test

**Benchmark manifest**:
The complete identity of one comparable performance run: source revisions,
binaries, build modes, route and runtime configuration, workload, client and
server topology, CPU and microcode, kernel, proxies, toolchain, sigbench, power
policy, affinity, and selected measurements.
_Avoid_: Machine name, informal benchmark setup

**HTTP load driver**:
Ploof's bounded, fixed-storage HTTP/1.1 client for real-runtime and deployment
measurements. It validates exact responses and reports closed-loop or
scheduled constant-rate throughput, failures, bytes, and finite latency
histograms. It supplies transport load and validity data; sigbench still owns
microbenchmark sampling, comparison, and regression statistics.
_Avoid_: Sigbench replacement, unvalidated request flooder

**Release notes artifact**:
The deterministic generated document bound to one semantic version, complete
candidate revision, support matrix, artifact identities, migrations, security
changes, and benchmark evidence. The reviewed source inputs and generator are
versioned; unresolved template text or hand-edited output cannot become a
release artifact.
_Avoid_: Mutable release description, unbound template

**Scoped benchmark measurement**:
One explicit start and stop boundary inside a custom benchmark callback. Case
setup, priming, and teardown remain outside wall or hardware-counter samples;
the complete repeated operation and its validity oracle remain inside.
_Avoid_: Whole-case counter, hand-returned nanoseconds for hardware events

**Performance baseline**:
Saved sigbench samples and resource results from the merge base measured beside
the candidate under the same benchmark manifest. Historical results from a
different manifest are reports, not regression evidence.
_Avoid_: Best-ever number, portable speed constant

**Feature tax**:
The measured difference between otherwise identical benchmark cases with one
Ploof facility disabled and enabled or exercised. It includes worker and helper
CPU and memory rather than only the request callback.
_Avoid_: Microbenchmark estimate, undocumented overhead

**Server lifecycle**:
The irreversible startup, readiness, drain, and stopped state of one running
Ploof application. It is observable for deployment coordination but does not
register an HTTP health path automatically.
_Avoid_: Restartable server handle, implicit readiness route

**Shutdown incomplete**:
The bounded terminal report that forced cancellation did not prove every
operation, finalizer, helper job, and middleware unwind quiescent. The server
is not called stopped and its live state cannot be deinitialized safely.
_Avoid_: Successful timeout, abandoned ring state

**Process-exit required**:
The terminal fatal report used when ring teardown cannot prove ownership of an
accepted descriptor or an asynchronous close. Known application work is
aborted and sensitive storage is cleared, but the worker is failed rather than
stopped and the hosting process must terminate before any descriptor number is
reused.
_Avoid_: Quiescent cleanup, blind duplicate close

**Request observation**:
One fixed-size record of a request's static route identity, bounded wire
measurements, and closed application and transport outcomes after its lifecycle
finishes. It contains no implicit request-controlled strings.
_Avoid_: Request dump, dynamic telemetry map

**Metrics snapshot**:
A complete bounded copy of worker-owned cumulative metric cells taken at safe
event-loop points. Exporters consume the snapshot rather than reading or
atomically updating shared hot-path state.
_Avoid_: Live metrics registry, request-label map

**Metrics exposition**:
One ordinary explicit application route that defers its response head while a
server-owned helper formats a complete **metrics snapshot**. One generation
ticket owns the helper's borrowed output through transport completion.
_Avoid_: Reserved metrics endpoint, partial snapshot, request-owned helper

**Access event**:
The fixed-size, allocation-free logging record emitted from one request's
`after` phase into a bounded worker queue. Formatting and sink I/O occur off the
request worker and routine events may be dropped rather than applying
backpressure.
_Avoid_: Audit event, synchronous request log

**Edge proxy**:
A trusted reverse proxy that accepts public client traffic for a **Ploof
application** and forwards requests to it.
_Avoid_: Caddy, TLS proxy

**Route graph**:
The closed set of HTTP method and path patterns that determines which
application behavior receives each request.
_Avoid_: Router configuration, mutable route table

**Route-graph limits profile**:
The comptime bounds on routes, pattern bytes, path segments, captures,
middleware depth, concrete middleware-state bytes, aggregate pattern bytes and
segments, index nodes, and worst-case search visits and compared bytes. Actual
graph maxima size generated indexes and request workspaces; configured ceilings
reserve nothing. Compilation rejects a graph whose exact conservative bound
exceeds its profile.
_Avoid_: Runtime router capacity, unlimited routes

**Route-search workspace**:
The fixed frame and path-token storage owned by each worker and reused for one
route search at a time. A route plan does not borrow it; capture spans are
materialized later into the request slot, so head/body state can outlive scratch
reuse without allocation.
_Avoid_: Router stack, borrowed route plan

**Request plan**:
The shallow copy of one admitted request's descriptors, canonical method and
path interpretation, route-graph decision, body policy, and feature state that
crosses from head admission into application preparation. Shallow fingerprints
detect stale or accidentally mutated configuration before lifecycle mutation;
they are coherence checks, not an authentication capability. Borrowed
request-head and decoded-path storage stays live and immutable through request
completion, while later body selection is one checked refinement to a decoder
already declared by the selected route.
_Avoid_: Owned request bytes, mutable route choice, security token

**Runtime-capacity profile**:
The explicit comptime bounds that shape worker slots, request workspaces,
provided buffers, response chunks, and ring queues. Startup creates or accepts
that concrete storage and reports its per-worker and process-wide byte budget;
changing a capacity recompiles the application.
_Avoid_: Request-time resizing, hidden default heap

**Effective host**:
The validated request authority exposed after applying the listener's explicit
proxy-trust policy. It is request metadata, not an input to the **route graph**.
_Avoid_: Host route, virtual host route

**Route parameter**:
A named path value captured when the **route graph** selects application
behavior. Its later conversion to an application type does not select a
different route.
_Avoid_: Typed route, route converter

**Middleware chain**:
The bounded, compile-time-closed sequence wrapping one route. Application,
group, and route middleware can participate in `head`, `body`, `response`, and
`after` phases. `head` runs before body intake, `body` sees bounded decoded data
or stream events, `response` runs in reverse order before response commitment,
and `after` runs in reverse order after transmission finishes or aborts. Head
and body phases may short-circuit; response may transform the result; after is
observation and cleanup only.
_Avoid_: Runtime middleware stack, interceptor registry

**Middleware state**:
The fixed-size typed request-local value shared by one middleware instance's
phases. The route graph determines its layout at comptime, and the runtime keeps
it in the preallocated request slot across I/O completions.
_Avoid_: Context value map, middleware-local allocation

**Response**:
The typed staged result returned by an ordinary handler or short-circuiting
middleware phase. It describes status, headers, and a finite body without
committing bytes until middleware `response` phases have finished. Streaming
uses a separate contract because its body can be committed before production
ends.
_Avoid_: Implicit response writer, handler side effect

**Response workspace**:
Startup-created storage borrowed by one active request for staged response
fields, safe dynamic body copies, and serialization. Dynamic body capacity is
selected per application at comptime; its standard 16 KiB can be disabled or
raised through the 16 MiB hard bound. The head maximum can serve routes with
smaller logical profiles; those route limits still govern mutation.
_Avoid_: Per-response heap, route limit bypass

**Transport outcome**:
The immutable completion or abort result supplied to middleware `after`. It
distinguishes ordinary completion, HEAD-suppressed completion, and transmission
failure without allowing already committed bytes to be replaced.
_Avoid_: Mutable response result, application status alone

**Streaming response**:
A `Context.StreamResponse(P)` containing a typed, Context-owned response head
and one incremental body descriptor with concrete producer `P`. Its bytes may
be committed before the producer finishes. Status, headers, and possible
response-trailer names are fixed before commitment; completion supplies the
terminal outcome and any response-trailer values.
_Avoid_: Unbuffered Response, mutable response writer

**Response framing**:
The runtime-owned mapping from a typed response body to HTTP/1.1 message
boundaries. Fixed wire bytes use an exact length, unknown streams use chunked
transfer coding, and exact streams must produce their declared byte count.
Applications select a body shape rather than writing framing or hop-by-hop
headers.
_Avoid_: User Content-Length, manual chunking

**Bodyless response**:
A response whose request method or status forbids content on the wire. HEAD
suppresses the selected representation without running its stream producer;
informational, 204, 205, and 304 results must be constructed without a body or
trailers.
_Avoid_: Empty body write, silently discarded body

**Response status**:
The typed numeric outcome of a final response. Named standard values and valid
unregistered values from 200 through 599 share one non-exhaustive type; textual
reason phrases are HTTP/1.1 serialization metadata, not application data.
_Avoid_: Status message, arbitrary integer status

**Application failure**:
A member of the application's closed Zig error set indicating that a request
could not be completed as intended. Expected HTTP outcomes are Responses, not
application failures; one central mapper turns failures into safe Responses.
_Avoid_: HTTP exception, status-code error

**Content coding**:
A bounded streaming transformation named by HTTP `Content-Encoding`. Ploof
version one supports `identity` and `gzip` for requests and eligible Responses;
content coding is distinct from HTTP transfer coding. Other codings receive an
unsupported result rather than being guessed or partially decoded.
_Avoid_: Transfer compression, compressed route

**Body decoder table**:
A route's comptime list of one to four non-overlapping media decoders. Request
`Content-Type` selects one generated path before body intake; selection never
uses method guessing, sniffing, or failed-parser fallback.
_Avoid_: Automatic binding, global body parser stack

**Finite body view**:
An immutable request-scoped view over ordered content-decoded worker chunks.
Byte and UTF-8 text variants avoid an implicit full-body copy; a route requests
contiguous storage explicitly when required.
_Avoid_: Raw wire body, automatic coalescing

**Request workspace**:
A fixed slot leased from a per-worker pool created at startup. Route composition
calculates its layout; request handling borrows or writes within it without
calling an allocator. Every potentially exposed range is cleared before reuse;
exposing the full slot keeps the full slot tainted even after a shorter commit.
_Avoid_: Request heap, allocation fallback

**Workspace exhaustion**:
A route-specific admission failure after request-head parsing when that worker's
required workspace class has no free slot. Ploof returns a preallocated 503 and
closes rather than queueing the body or allocating fallback memory.
_Avoid_: Workspace wait queue, overload heap

**Byte/text body media**:
The explicit media patterns selecting a finite byte or UTF-8 text decoder.
Defaults are `application/octet-stream` and `text/plain`; wildcard acceptance is
route-declared and never substitutes for a missing `Content-Type`.
_Avoid_: Sniffed body kind, implicit any-content parser

**Response media type**:
The explicit representation format attached by a typed response helper or file
extension lookup. JSON, HTML, text, and raw bytes have deterministic defaults;
Ploof never guesses a media type from body bytes.
_Avoid_: Sniffed content type, filename-only type

**HTML template**:
A named HTML representation whose placeholders, helpers, and partials form a
closed contract with one **template view**.
_Avoid_: Runtime view, interchangeable template engine

**Finite HTML response**:
A complete bounded HTML representation rendered from one closed template graph
before response commitment. Incremental page production uses a distinct
streaming contract rather than changing this response implicitly.
_Avoid_: Automatic template stream, unbounded rendered page

**Response chunk chain**:
One ordered finite body assembled in worker-owned fixed-size chunks and
transferred as a single tagged response source. The chain has an exact byte
length, is committed only after rendering and middleware succeed, and is
securely cleared before its chunks return to the worker pool.
_Avoid_: Scattershot response buffers, per-request chunk allocation

**Document template**:
A standalone **HTML template** representing one complete HTML document. It has
no layout body slot and cannot be composed as a fragment.
_Avoid_: Full-page fragment, inferred document

**Fragment template**:
An **HTML template** representing balanced markup in HTML body context. It may
be rendered directly or composed as a layout body or partial, but contains no
document shell.
_Avoid_: Partial document, implicit page shell

**Partial template**:
A complete reusable HTML fragment with its own **template view** and a static
place in another template's closed graph. It neither inherits ambient data nor
shares unfinished HTML structure with its caller.
_Avoid_: Dynamic include, attribute fragment

**Layout template**:
A complete HTML document with its own **template view** and one static body slot
for a separately typed **HTML template**. It provides page-wide structure
without sharing an ambient data scope with the body.
_Avoid_: Template inheritance, named-slot collection

**Template view**:
The typed application value supplying the data declared by one **HTML
template**. It is not a string-keyed bag shared by unrelated templates.
_Avoid_: Render locals, template context map

**Template interpolation**:
The placement of one **template view** value into an **HTML template**. Plain
interpolation represents untrusted text; URLs, browser data, and trusted markup
have distinct typed meanings rather than opting a string out of escaping.
_Avoid_: Raw insertion, already-escaped string

**Template helper**:
A statically named concrete presentation function that immediately transforms
typed template data into another supported value. It has no request services,
ambient scope, or runtime registration.
_Avoid_: Template plugin, global helper registry

**Template directive**:
A statically parsed `{{ ... }}` instruction for interpolation, typed control,
composition, or a built-in template operation. It is not a runtime expression
or embedded Zig statement.
_Avoid_: Template script, runtime expression

**Template source profile**:
The finite compile-time rules and limits under which one closed template graph
is valid. Applications may replace the standard profile with another explicit
finite profile.
_Avoid_: Browser-repaired template, unbounded compiler input

**Context-balanced block**:
A template control block whose every possible path returns to the same HTML
parser context in which it began. It may select complete static structure but
cannot make view data become markup structure.
_Avoid_: Attribute spread, fragmentary conditional

**Inline text**:
A finite UTF-8 presentation value stored by value for immediate template
interpolation. Its type states its maximum length, and it is neither an
allocated string nor a response body.
_Avoid_: Formatting allocation, unbounded helper string

**Browser data block**:
A statically named, non-executable JSON representation embedded in rendered
HTML for application JavaScript to parse. It carries request-specific data but
is never JavaScript source.
_Avoid_: Inline JavaScript state, raw JSON script

**Trusted HTML**:
A complete HTML fragment whose application-controlled provenance permits it to
bypass plain interpolation escaping in HTML body context. The trust covers both
its content and its ability to preserve the surrounding fragment structure.
_Avoid_: Safe string, raw output flag

**Static inline SVG**:
An application-authored balanced SVG graphics subtree containing no Ploof
directives or embedded foreign content. It is template source, not a dynamic
graphics representation.
_Avoid_: SVG template, trusted SVG value

**Embedded asset**:
An immutable application-owned file included in the built program. It normally
has its own HTTP representation and typed reference; explicit HTML templates
may instead place CSS or JavaScript bytes inline.
_Avoid_: Runtime asset file, template view data

**URL value**:
A complete validated browser destination used for navigation, form submission,
or a non-executable resource. It is distinct from both an **asset reference**
and a **trusted resource URL**.
_Avoid_: URL fragment interpolation, arbitrary href string

**Asset reference**:
The typed identity of one **embedded asset** and its HTTP representation. Its
declared media kind determines which HTML resource positions may use it.
_Avoid_: Asset pathname, untyped static URL

**Asset bundle**:
The finite set of content-addressed **embedded assets** carried by one Ploof
application build. A new build has a new bundle rather than mutating bytes at
an existing asset identity.
_Avoid_: Mutable static directory, implicit asset history

**Asset compiler**:
The package's deterministic host build artifact that turns explicitly supplied
application files into one generated asset-bundle module with identity and gzip
representations. It performs no network access or source-tree mutation.
_Avoid_: Runtime packer, application build system

**Asset origin**:
The application-controlled base from which an **asset reference** is rendered.
It is the local content-addressed route by default or one startup-validated
HTTPS origin and fixed path prefix for a trusted proxy or CDN. Request data
cannot select or modify it.
_Avoid_: Asset host header, request-selected CDN

**Static file mount**:
An ordinary route-graph mapping from one fixed URL prefix to a live filesystem
root opened during startup. It inherits normal middleware and serves only
confined regular files through bounded asynchronous I/O.
_Avoid_: Mutable asset bundle, directory browser

**Trusted resource URL**:
An explicitly trusted complete destination from which a browser may load
script, stylesheet, frame, or other active content. Ordinary URL validation
cannot confer this trust.
_Avoid_: Validated URL, user-controlled resource URL

**JSON response**:
A finite JSON representation encoded completely before response commitment.
Its endpoint declares `response_json_bytes_max`; its `jsonWith` call declares
any non-default depth or formatting policy. The selected endpoint workspace is
available to head middleware, the central error mapper, body handling, and
response middleware under the same bound. It rejects values JSON cannot
represent safely, keeps repeated encode attempts disjoint across caught errors
and body intake, and never changes automatically into a stream.
_Avoid_: Incremental JSON response, unbounded stringify

**Typed JSON body**:
One complete UTF-8 JSON value decoded from bounded stored body chunks into a
route-declared Zig type. Its token grammar, nesting, duplicate names, and
numeric conversions are validated before the handler runs.
_Avoid_: JSON object map, coercive body binding

**Unknown JSON field policy**:
The comptime rule for object members absent from a typed destination. Ploof
ignores them by default for additive compatibility or rejects them before the
handler when a route selects strict schema input.
_Avoid_: Extra fields map, global decoder switch

**JSON parse memory**:
Request-local storage owned by a typed JSON body beyond its retained wire
chunks. Escaped strings, cross-chunk strings, arrays, pointers, and dynamic
nodes consume its independent route limit; directly borrowable string bytes do
not.
_Avoid_: JSON heap, body-size alias

**JSON field schema**:
Optional type-local comptime metadata mapping Zig struct fields to exact JSON
names for both decoding and encoding. Field defaults define whether absence is
valid; optional field types independently define whether `null` is valid.
_Avoid_: Case-insensitive binding, implicit naming convention

**JSON codec hook**:
A comptime-checked `jsonParse` or `jsonStringify` customization that consumes or
emits one structured value through Ploof's bounded codec. It cannot inject raw
JSON or bypass global grammar, memory, depth, and response-size invariants.
_Avoid_: Raw JSON hook, unchecked custom serializer

**JSON codec application failure**:
A finite application-owned operational failure explicitly declared by a JSON
encode hook. It reaches the central error mapper and cannot share an identity
with JSON, template-rendering, or response-transport failures.
_Avoid_: Custom encoder error, framework error alias

**JSON wire DTO**:
A Zig struct whose declared fields are one HTTP JSON representation. Different
request and response shapes use different structs; field metadata does not hide
sensitive members in only one direction.
_Avoid_: Domain object serializer, directional field flag

**JSON null omission**:
An explicit output option on an optional field that removes the complete member
when its value is null. Null is emitted by default; false, zero, and empty
values are never treated as null or implicitly omitted.
_Avoid_: Global omit-null, broad omitempty

**Dynamic JSON value**:
A request-scoped tagged JSON tree whose arrays and ordered object members live
contiguously in bounded parse memory. Numbers retain validated lexemes, and
lookups are exact and non-coercive without an automatic object hash table.
_Avoid_: Any map, f64 JSON tree, unbounded DOM

**Decoded output mailbox**:
The fixed single-producer, single-consumer handoff owned by one gzip decoder
slot. It publishes at most one borrowed decoded chunk until the worker feeds
the body consumer and acknowledges it, bounding memory and propagating socket
backpressure without retaining the complete decoded body.
_Avoid_: Decoded body buffer, unbounded decoder queue

**Upload stream**:
The bounded sequence of multipart file bytes pushed through short-lived,
borrowed chunks without retaining the whole file in memory. A consumer handles
each chunk or submits bounded asynchronous sink work; the runtime pauses input
while that work is pending. Part headers, field data, file data, and total bytes
each have explicit limits.
_Avoid_: Uploaded file buffer, unlimited multipart body

**Upload sink window**:
The finite number of ownership-transferred file chunks whose asynchronous work
may be pending for one multipart request. Socket intake pauses when full; all
operations finish or are reaped before file completion and buffer reuse.
_Avoid_: Unbounded upload queue, one-write-at-a-time rule

**Multipart file route bound**:
The application-wide maximum of 512 routes whose multipart schema declares a
`File` variant, including discard-only and synchronous file sinks. It is lower
than the 4,096-route graph bound because typed file-operation specialization is
generated per route and operation.
_Avoid_: Async-only route bound, 4,096 specialized file handlers

**Upload transaction**:
The staged lifetime of all durable multipart sinks begun by one request. After
the entire body and pre-commit response validate, the completion handler
explicitly commits or aborts them; each sink owns its bounded staging and
cleanup mechanism.
_Avoid_: Immediately durable file callback, implicit temporary file

**Multipart boundary**:
The validated one-to-seventy-byte token separating multipart sections on strict
CRLF lines. Boundary-like part data is not a delimiter without a complete valid
suffix; delimiter transport padding has its own route-local finite byte bound,
while ignored preamble, padding, and epilogue still consume the decoded body
limit.
_Avoid_: HTTP body terminator, LF-tolerant separator

**Nested multipart payload**:
A part whose own media type is `multipart/*`. Standard Ploof decoding never
recurses into it: route-declared files and byte fields keep it opaque, while a
text field rejects its unsupported media type.
_Avoid_: Inner multipart route, automatic multipart/mixed compatibility

**Multipart part metadata**:
The schema-relevant name, optional untrusted client filename, and optional
media type retained for one part. Other valid part headers consume syntax and
count limits but are discarded instead of becoming a generic metadata map.
_Avoid_: Part header map, custom header escape hatch

**Multipart part cardinality**:
One schema entry's required-or-optional presence and finite maximum occurrence
count. Entry overflow or missing required data is malformed shape; route-wide
resource exhaustion remains a separate limit failure.
_Avoid_: Last value wins, unlimited repeated part

**Multipart typed field**:
A complete UTF-8 ordinary field converted with the shared strict flat-value
grammar before its synchronous callback. Inline values can enter fixed request
state; values borrowing the reusable field buffer expire with the callback.
_Avoid_: Retained multipart DTO, multipart-only coercion

**Multipart consumer state**:
One concrete request-local typed value initialized after body admission, updated
by synchronous field callbacks, and passed to route completion only after the
entire multipart representation and outer content coding validate. Earlier
callback effects must remain abortable request state.
_Avoid_: Global callback side effect, partially committed upload response

**Upload sink type**:
The concrete comptime-known implementation assigned to one declared file part.
Its maximum repeated state is laid out in request workspace; runtime backend
selection requires an explicit application-owned tagged union.
_Avoid_: Upload plugin registry, boxed sink interface

**File media claim**:
The optional parsed media type supplied by a client for one uploaded file. A
comptime acceptance policy can filter it before sink creation, but only an
explicit content verifier examines bytes and can establish route-specific
format validity.
_Avoid_: Verified MIME type, filename-derived type

**File acceptance policy**:
A comptime-known file-start decision that either admits a schema-declared file
or rejects the request. It never silently converts submitted data into an
absent file; intentional disposal requires an explicit sink.
_Avoid_: Silent file filter, policy-driven skip

**Upload sink poller**:
One fixed-state sink lifecycle or pending-write machine that alternates between
a typed start/completion event and either completion or one normalized I/O
request. Ploof owns ring submission, cancellation, and completion reaping.
_Avoid_: Upload coroutine, raw io_uring sink access

**Upload I/O requirements**:
The exact set of normalized operations an upload sink may request. A route's
requirements are the union of its declared sinks.
_Avoid_: Staging-mode capability, opportunistic operation

**Upload finalization order**:
The original file-start sequence used for one-at-a-time commit and reversed for
abort or compensation. Cleanup attempts continue after individual failures;
client disconnect after a commit decision does not cancel finalization.
_Avoid_: Parallel commit race, stop-on-first-cleanup-error

**Filesystem upload sink**:
The first-party concrete sink that stages an upload beneath a startup-opened
root directory and commits it to an application-supplied `StorageKey` without
overwriting. Its comptime configuration requires a root and durability mode,
defaults to anonymous staging, a 256-byte configurable key maximum capped at
4,095 bytes, and mode `0600`. Client filename metadata can never become that
key implicitly.
_Avoid_: Save-to-client-filename helper, hot-path directory creation

**Storage key**:
A bounded validated UTF-8 relative path supplied by application code to
`FileSink`. Its exact components resolve beneath a startup root without
symlinks or mount crossings and are retained in fixed sink state.
_Avoid_: Client filename path, normalized path string

**File staging mode**:
The startup-selected `FileSink` mechanism: anonymous filesystem state required
by default, or an explicit securely named compatibility directory that can
retain crash orphans. Runtime fallback between modes is forbidden.
_Avoid_: Silent O_TMPFILE fallback, auto-deleted unknown staging file

**Upload namespace ownership**:
The deployment rule that a `FileSink` staging directory and destination key
remain controlled by the service throughout staging, commit, and reverse
compensation. Tracked handles and no-replace publication prevent in-process
confusion; Linux cannot conditionally unlink a path by open-descriptor identity
against a hostile external directory writer.
_Avoid_: Shared writable upload directory, descriptor-conditional unlink

**File durability mode**:
The required `FileSink` choice between page-cache-backed atomic publication and
publication synchronized through file and affected-directory `fsync` calls.
Logical transaction commit does not imply crash durability unless the latter is
selected.
_Avoid_: Implicit fsync policy, data-only durability claim

**Multipart limits profile**:
A route-local comptime value bounding total bytes, file bytes, fields, parts,
files, part headers, disposition parameters, delimiter padding, names, and
boundaries. The standard profile is a safe default rather than a server ceiling
and can be overridden inline.
_Avoid_: Multipart memory limit, global upload size

**Multipart part schema**:
A route's comptime mapping from exact part names to ordinary-field or streamed-
file behavior and finite cardinality. Filename and media-type metadata never
select the processing path.
_Avoid_: Filename-classified upload, dynamic part map

**Multipart field representation**:
A route-declared ordinary part kind: UTF-8 text by default or explicit arbitrary
bytes. Charset metadata never changes file content or byte fields, and
`_charset_` has no parser effect.
_Avoid_: Implicit binary text field, multipart transcoding

**Multipart field callback**:
One synchronous delivery of a complete bounded text or byte field through a
borrowed slice. One preallocated buffer is reused between fields; only declared
files expose chunks.
_Avoid_: Retained field slice, streamed ordinary field

**Unknown multipart part policy**:
The route rule for a part name absent from its schema. Ploof rejects by default;
bounded streaming discard is explicit and never creates storage or callbacks.
_Avoid_: Implicit upload acceptance, unbounded unknown drain

**Multipart part headers**:
The bounded ordered metadata preceding one part. Exactly one form-data
disposition with a non-empty name is required; alternate transfer encoding,
folding, singleton duplication, and malformed values are rejected; every
disposition parameter counts even when unknown, and duplicate parameter names
are rejected case-insensitively.
_Avoid_: MIME mail compatibility, merged part headers

**Client filename**:
Optional request-scoped UTF-8 upload metadata parsed from exactly one filename
form. It is never normalized, treated as a path, or used to select file
processing; storage names remain application-generated.
_Avoid_: Safe filename, upload path

**Empty file marker**:
An explicit empty client filename with zero content representing an unselected
browser file input. It counts as a part but not an admitted file and produces no
file callbacks; payload bytes make it malformed.
_Avoid_: Empty uploaded file, silently discarded file

**Continue gate**:
The route, framing, limit, and middleware `head` checks completed before Ploof
answers `Expect: 100-continue`. It produces either an immediate final Response
or permission to receive the body.
_Avoid_: Expect middleware, provisional handler

**CSRF policy**:
First-party middleware explicitly applied to cookie-authenticated application
or route groups. It combines an early request-head gate with constant-time token
validation in the body phase for unsafe methods.
_Avoid_: SameSite-only protection, automatic global CSRF

**CSRF token mode**:
The explicit session model used by a CSRF policy: either a server-stored
synchronizer token or a signed double-submit token bound to random per-login
identity. Ploof does not infer a mode or provide naive double-submit.
_Avoid_: CSRF default, unsigned double-submit cookie

**CSRF token source**:
The one physical header, URL-encoded form field, or reserved multipart field
that satisfies an unsafe request's CSRF policy. Repetition or a second source
is a rejection even when values match; query values never participate.
_Avoid_: Token precedence, first token wins

**CSRF-gated file admission**:
The one-pass multipart boundary before which Ploof invokes no application file
callback, sink begin, or sink write. A later duplicate token aborts conforming
staged sinks and prevents commit; it cannot undo kernel receipt or arbitrary
irreversible effects performed by dishonest extension code.
_Avoid_: Whole-upload buffering, rollback of arbitrary application side effects

**CORS policy**:
An explicit application, group, or route policy controlling which browser
origins may read responses and which matching preflights Ploof answers. It can
be disabled, allow any non-credentialed origin, allow an exact set, or
explicitly reflect any credentialed origin. Opaque `null` origins require a
separate opt-in. Exact policies contain at most 64 comptime-parsed origins and
64 exact requested-header names. Permission serialization fails closed through
complete, `Vary`-only, and empty bounded representations; a generated 204
preflight becomes 403 if its complete permission fields cannot fit. It is not
authentication, request blocking, or CSRF protection.
_Avoid_: CORS security boundary, wildcard credentials

**Canonical public origin**:
A startup-configured public scheme, host, and effective port used to validate
the effective deployment origin for CSRF and other origin-sensitive features.
Ordinary servers need not configure one, and a request or forwarded header can
select but never create one.
_Avoid_: CORS allowed origin, inferred proxy origin

**CSRF source origin**:
An exact startup-configured browser Origin or Referer origin allowed to submit
an unsafe cookie-authenticated request. It defaults to canonical public origins
but may differ without widening the accepted effective deployment hosts.
_Avoid_: CORS allowed origin, canonical public origin

**Transport peer**:
The immutable address of the process directly connected to Ploof's socket. It
is evaluated against listener trust configuration before any proxy claim.
_Avoid_: Remote user, client IP

**Client address**:
The originating address resolved from the transport peer and one explicitly
configured proxy metadata format. It is a claim with recorded provenance, not
an alias for the transport peer.
_Avoid_: Remote address, real IP

**Forwarding profile**:
Per-listener startup configuration containing trusted transport peers, whether
PROXY v2 is required, the one accepted HTTP forwarding family, hop bounds, and
whether direct untrusted peers are allowed.
_Avoid_: Trust proxy, proxy mode

**Request-head limits profile**:
A listener policy bounding the request line, header bytes, and physical header
fields before routing. Its standard values fit common edge-proxy limits and can
be replaced for an application with larger legitimate metadata.
_Avoid_: Header buffer size, parser allocation

**Request-head admission**:
The mandatory semantic gate between strict request-head parsing and dispatch.
It validates the target, query, message framing, `TE`, and request-trailer
declarations as one outcome. Failure closes the connection; no route or
middleware observes a partially accepted request.
_Avoid_: Optional request validation, handler preflight

**Header values**:
The ordered set of field values received under one case-insensitive HTTP field
name. It remains plural until application behavior explicitly selects a
cardinality or field-specific parser. Normal values remove surrounding optional
whitespace; explicit raw iteration preserves received spelling and bytes.
_Avoid_: Header string, automatically joined header

**Response header fields**:
The bounded ordered field lines assembled before response commitment. Names are
case-insensitive and serialized lowercase; `set` replaces, `append` adds one
physical line, and `remove` deletes a name. Values are never generically joined
with commas.
_Avoid_: Response header map, combined Set-Cookie

**Response-head limits profile**:
An application default, optionally replaced per route at comptime, bounding the
complete serialized response head, one field line, and physical field count.
It is a protocol-work limit, not an equal per-connection memory reservation,
and must fit the deployed edge proxy's upstream limits.
_Avoid_: Header allocation size, proxy buffer setting

**Response-trailer plan**:
The declaration token returned when the response head is committed. An emitting
plan borrows declaration storage, which must remain alive and immutable until
the terminal chunk. A non-emitting plan borrows nothing and permits no terminal
trailer values.
_Avoid_: Repeated trailer-name list, mutable terminal headers

**Automatic response fields**:
Protocol metadata written by the runtime rather than application handlers.
Ploof emits a cached `Date` on final responses and `Connection: close` only when
closing. It advertises no framework identity by default; an application can
opt into one static `Server` identity. Edge-owned protocols remain absent.
_Avoid_: Default framework banner, handler-written Date

**Query values**:
The ordered byte values attached to one decoded flat query name. Repeated names
remain plural until application behavior selects a cardinality or typed binding;
bracket spelling does not create an implicit nested object.
_Avoid_: Query object, nested query map

**Form source**:
The ordered URL-encoded fields decoded only from a request body. It remains
distinct from URI query values, with no implicit precedence or merged binding.
_Avoid_: Merged request form, body-over-query value

**URL-encoded form**:
A bounded body parsed with the same strict flat name/value grammar as a query.
Repeated names remain ordered, bracket spelling remains literal, and nesting is
not inferred.
_Avoid_: Extended form object, nested bracket parser

**Form charset**:
The single UTF-8 interpretation of a URL-encoded body. A missing charset means
UTF-8, another declared charset is unsupported, and every decoded name and value
is validated before any form data becomes visible.
_Avoid_: Charset sentinel, legacy form transcoding

**Field cardinality**:
The occurrence count a typed flat-input field accepts. Scalars require one,
slices consume all in wire order, and fixed arrays require their exact length;
no value is selected implicitly from duplicates.
_Avoid_: First value, last value, scalar-or-array

**Empty flat segment**:
A leading, trailing, or adjacent ampersand segment that consumes parser-work
budget but creates no field. An explicit equals sign can still create a retained
field whose name is empty.
_Avoid_: Empty-name separator field, free separator noise

**Flat-field absence**:
A missing typed query or form name resolved only through its Zig field default.
Present empty or invalid bytes never trigger the default, and flat formats have
no textual null value.
_Avoid_: Empty-as-missing, invalid-as-default

**Flat scalar conversion**:
The exact, type-directed conversion from one decoded query or form value. Text
is UTF-8, numbers are bounded decimal forms, booleans have four accepted
spellings, and enums match tag names without trimming or coercion.
_Avoid_: Best-effort binding, zero-value coercion

**Flat field schema**:
Type-local comptime metadata mapping Zig struct fields to exact, case-sensitive
names shared by query and URL-encoded form binding. Different source contracts
use different DTOs.
_Avoid_: Case-insensitive form tag, query alias set

**Unknown flat field policy**:
The comptime rule for query or form names absent from a typed destination.
Ploof ignores them by default or rejects them before handler entry when that
binder selects strict schema input.
_Avoid_: Extras map, global strict-form switch

**Text parser hook**:
An allocation-free, comptime-checked `parseText` function that converts one
decoded flat value into an inline result or a view borrowing request input. It
cannot access request state, scratch storage, I/O, or application failures.
_Avoid_: Parser registry, allocator-taking text hook

**Request trailers**:
Declared request metadata received only after a chunked body completes. Request
trailers remain separate from header values and are unavailable to decisions
that must happen before or during body intake.
_Avoid_: Late headers, merged headers

**Chunked-request profile**:
The comptime bounds on nonterminal chunk count and request-trailer section,
field-line, declared-name, and physical-field counts. One profile governs the
request consistently from head admission through body completion.
_Avoid_: Per-route chunk parser limits, runtime decoder resizing

**Chunked workspace slot**:
A startup-sized worker-local lease whose storage is reused first for chunk
framing and then for declared request trailers. It remains leased through
request completion because application trailer views borrow it.
_Avoid_: Per-request chunk decoder, trailer heap allocation

**Response trailers**:
Optional, predeclared metadata emitted after a successful streaming response
body. Ploof sends it only when the request negotiated trailers; values become
available at stream completion and must never carry information essential to
interpreting the response.
_Avoid_: Guaranteed metadata, streaming headers

## Example dialogue

**Developer:** Does this Ploof application need a separate HTTP server or
framework?

**Maintainer:** No. It is one Ploof application; Ploof covers the complete
request-to-response boundary.

**Developer:** Why compare Ploof with Gin and Express?

**Maintainer:** Their users are Ploof's adoption target. A developer moving the
same kind of service to Zig should recognize the concepts without giving up
Zig's type system or comptime model.

**Developer:** Must every Ploof default equal both frameworks?

**Maintainer:** No. They disagree with each other. They form the comparison
baseline, so Ploof documents why a public default differs instead of creating
an accidental outlier.

**Developer:** Must its edge proxy be Caddy?

**Maintainer:** No. Edge proxy names the role; nginx, HAProxy, Envoy, Caddy,
or another suitable product can fill it.

**Developer:** Can a tenant add another endpoint after startup?

**Maintainer:** No. The Ploof application's route graph is already complete;
tenant-specific behavior belongs behind one of its routes.

**Developer:** Does `/users/:id` select another route when `id` is not an
integer?

**Maintainer:** No. `id` is a route parameter; the selected behavior decides
which application type it must convert to.

**Developer:** Can two handlers use the same method and path for different
hosts?

**Maintainer:** No. The route graph uses method and path. The edge proxy can
separate domains, while handlers can read the effective host when needed.

**Developer:** Can middleware measure the completed handler response?

**Maintainer:** Yes. Its `head` phase records middleware state, its `response`
phase can transform the result before commitment, and its `after` phase observes
the immutable transport outcome after transmission finishes or aborts.

**Developer:** Can CSRF middleware compare a form token with session state?

**Maintainer:** Yes. Its `head` phase records the expected token in middleware
state. Bounded form and multipart parsing update that same concrete state before
typed body binding or file admission, without a string-keyed context bag.

**Developer:** How does a handler send JSON?

**Maintainer:** It returns a Response produced by the JSON helper; it does not
silently mutate and commit a shared response writer.

**Developer:** Is a missing resource an application failure?

**Maintainer:** Usually no. The handler returns a 404 Response. Application
failures represent operational failure and flow to the central error mapper.

**Developer:** Must a compressed JSON body be buffered before Ploof can reject
it as too large?

**Maintainer:** No. Its content coding is decoded incrementally and stopped at
the route's decoded-body limit.

**Developer:** Does version one accept Brotli request bodies?

**Maintainer:** No. Its content codings are identity and gzip; unsupported
request codings receive 415.

**Developer:** Does a large uploaded file consume an equally large buffer?

**Maintainer:** No. A multipart file is exposed as an upload stream with fixed
memory bounds.

**Developer:** Can an upload consumer keep a chunk after its callback returns?

**Maintainer:** No. The chunk is borrowed. It must consume it immediately or
submit bounded sink work that transfers ownership to the runtime.

**Developer:** Does one slow upload write allocate more buffers?

**Maintainer:** No. It can occupy only its declared sink window; once full,
Ploof pauses that socket until a preallocated chunk completes.

**Developer:** Can adding `filename=x` turn a declared CSRF field into a file?

**Maintainer:** No. The route schema fixes that name as an ordinary field, so
filename metadata on it is a 400 kind mismatch.

**Developer:** Does ignoring an unknown upload store it temporarily?

**Maintainer:** No. Explicit ignore streams it directly to discard under its
own bound and every route multipart limit.

**Developer:** Does a part with `Content-Transfer-Encoding: base64` get decoded?

**Maintainer:** No. Per-part transfer coding is rejected; file chunks always
contain the bytes delimited by the multipart body.

**Developer:** Does `filename="../../etc/passwd"` become a storage path?

**Maintainer:** No. It remains an untrusted `ClientFilename` value. The
application generates a separate storage identifier.

**Developer:** Is `filename="empty.txt"` with zero bytes ignored?

**Maintainer:** No. It is a real empty file and emits start and end callbacks.
Only an empty filename with zero bytes is the no-file marker.

**Developer:** Can multipart `_charset_` switch later fields to Latin-1?

**Maintainer:** No. It is ordinary declared data. Text fields are UTF-8 and
binary fields must be declared explicitly.

**Developer:** Can a multipart field callback retain its slice?

**Maintainer:** No. It parses or copies the value during the callback; Ploof
reuses the same bounded field buffer for the next ordinary field.

**Developer:** Can a gzip multipart route complete before its footer arrives?

**Maintainer:** No. Decoded chunks may update request-local consumer state, but
`complete` runs only after gzip CRC32 and ISIZE, HTTP framing, and the multipart
closing delimiter all validate. Failure aborts that state and returns the
terminal 400, 413, or 415 response.

**Developer:** Does compressed multipart need a second whole-upload buffer?

**Maintainer:** No. Every decoder slot owns one receive-buffer-sized output
mailbox. The decoder blocks after publishing one borrowed chunk until the
worker feeds the parser and acknowledges it.

**Developer:** Is every upload limited to 16 MiB?

**Maintainer:** No. That is the standard multipart limits profile. A route can
replace individual limits at comptime without changing runtime memory use.

**Developer:** Will Ploof accept a large unauthorized body before rejecting it?

**Maintainer:** With `Expect: 100-continue`, no. The continue gate can return the
final response before body intake begins.

**Developer:** Does every Ploof API require a CSRF token?

**Maintainer:** No. CSRF policy is explicitly applied where browsers
automatically attach credentials, while bearer-only APIs can select another
policy.

**Developer:** Which CSRF token does Ploof use?

**Maintainer:** The application selects a CSRF token mode that matches its
session model; Ploof supports synchronizer and signed double-submit modes.

**Developer:** Can a public API allow every browser origin?

**Maintainer:** Yes. Its CORS policy can allow any non-credentialed origin with
`*`; credentialed allow-any is a separate explicit reflection mode.

**Developer:** Must I add an OPTIONS route for browser preflights?

**Maintainer:** No. The CORS policy answers matching preflights from the route
graph before the route handler runs.

**Developer:** Does every route-matched CORS preflight return 204?

**Maintainer:** Ploof prepares an allowed preflight as 204, but changes it to
403 if the complete permission fields cannot fit the configured response or
output limits. It never emits a partial permission grant.

**Developer:** Does allow-any CORS also allow `Origin: null`?

**Maintainer:** No. Opaque origins share that serialization and require an
explicit `allow_null` opt-in.

**Developer:** Must that public API declare the hostname where it is deployed?

**Maintainer:** No. Canonical public origins become mandatory only when the
application enables an origin-sensitive feature such as CSRF.

**Developer:** Is the address in `X-Forwarded-For` automatically the client?

**Maintainer:** No. The listener's forwarding profile first authenticates the
transport peer, then resolves a bounded chain into a client address with
recorded provenance. A PROXY v2 source starts client-chain walking; it does not
cancel the authenticated transport's authority to provide selected host and
scheme metadata.

**Developer:** Can an application accept request metadata larger than the
standard limits?

**Maintainer:** Yes. It can replace the listener's request-head limits profile
within Ploof's hard protocol ceiling.

**Developer:** Can middleware handle a malformed query or `TE` field itself?

**Maintainer:** No. Request-head admission rejects it and closes before route
selection, so middleware never sees a partially accepted request.

**Developer:** What does reading a repeated application header return?

**Maintainer:** Header values. The application explicitly requires one value,
selects the first, iterates them, or invokes that field's typed parser.

**Developer:** Can diagnostics inspect the field exactly as received?

**Maintainer:** Yes. Raw iteration is explicit; ordinary header values retain
semantic bytes without name casing or surrounding whitespace concerns.

**Developer:** Does `filter%5Bname%5D=Ada` create a nested query object?

**Maintainer:** No. It decodes to the one flat name `filter[name]`. Raw brackets
are not valid URI query bytes; typed application binding decides whether the
decoded spelling has meaning.

**Developer:** Can a query `csrf=bad` override a URL-encoded body `csrf=good`?

**Maintainer:** No. Query and form-body values are separate inputs. A route must
explicitly combine them if it wants precedence.

**Developer:** Does a form field named `user[name]` create a nested object?

**Maintainer:** No. It remains the literal flat name `user[name]`; the URI query
spelling of that name would percent-encode its brackets.

**Developer:** Can a form field named `_charset_` select ISO-8859-1?

**Maintainer:** No. It is ordinary application data. Ploof accepts only UTF-8
URL-encoded forms.

**Developer:** Which value does a scalar receive from `role=user&role=admin`?

**Maintainer:** Neither. A scalar declares exactly one occurrence, so the typed
query or form binding fails with 400.

**Developer:** Does `&&name=value&` expose three empty-name fields?

**Maintainer:** No. Its empty segments count toward the limit but create no
fields; only `name=value` is exposed.

**Developer:** Does `limit=` use `limit: u16 = 50`?

**Maintainer:** No. The field is present and its empty value cannot decode as a
number, so binding fails with 400. Only an absent `limit` uses 50.

**Developer:** Does `enabled=TRUE` bind to a boolean?

**Maintainer:** No. Use `enabled=true` or `enabled=1`; accepted spellings are
exact so clients cannot depend on case folding.

**Developer:** Does a flat field named `user_id` bind automatically to
`userId`?

**Maintainer:** No. Rename it explicitly in flat-field metadata or use the exact
Zig field name.

**Developer:** Does ignoring an unknown form field avoid the segment limit?

**Maintainer:** No. It still passes wire and UTF-8 validation and consumes one
segment; ignoring only prevents it from entering the typed result.

**Developer:** Can a UUID parser allocate from the general heap?

**Maintainer:** No. It returns an inline value or borrows its input. A
transformation requiring owned bytes happens explicitly in handler-owned
storage.

**Developer:** Can authentication arrive in request trailers?

**Maintainer:** No. Authentication must be decided before body intake; request
trailers are late metadata for fields whose definitions permit that placement.

**Developer:** Can a streaming response put its checksum in a trailer?

**Maintainer:** Yes, as a response trailer when the client negotiated trailers.
The stream declares the name before commitment and treats the checksum as
optional because an intermediary may discard it.

**Developer:** Can the stream change its declared trailer names at completion?

**Maintainer:** No. Response-head commitment returns one response-trailer plan.
If it emits a declaration, the terminal chunk accepts values only under that
immutable borrowed plan. A non-emitting plan accepts no trailer values.

**Developer:** Can a handler set `Content-Length` directly?

**Maintainer:** No. It selects fixed, exact-stream, or unknown-stream response
framing. Ploof derives the wire fields and closes a connection if an exact
stream violates its declared size.

**Developer:** Does an implicit HEAD request run a streaming GET body?

**Maintainer:** No. Ploof builds the same response head and then applies
bodyless-response rules. It does not invoke the stream producer.

**Developer:** How do I return two `Set-Cookie` values?

**Maintainer:** Append two response header fields through the typed cookie
helper. Ploof preserves two physical lines and their insertion order.

**Developer:** Can one route return more than 16 KiB of response metadata?

**Maintainer:** Yes. Replace its response-head limits profile at comptime and
configure the edge proxy to accept the same serialized size.

**Developer:** Does every response call the wall clock to build `Date`?

**Maintainer:** No. `Date` is an automatic response field cached per worker for
the current second.

**Developer:** Can an application return private status 499?

**Maintainer:** Yes. Construct a validated response status from 499. HTTP/1.1
uses an empty reason phrase because that extension code has no standard text.

**Developer:** Will raw bytes starting with `<html>` become HTML?

**Maintainer:** No. Their response media type remains
`application/octet-stream` unless the application explicitly replaces it.

**Developer:** Does a large `Response.json` begin streaming automatically?

**Maintainer:** No. A JSON response either finishes within its route's encoded
limit before commitment or fails. Indefinite JSON uses an explicit streaming
response contract.

**Developer:** Does a quoted JSON value `"42"` bind to a Zig integer?

**Maintainer:** No. A typed JSON body preserves JSON types; numeric coercion is
an application conversion after successful parsing.

**Developer:** If JSON parsing fails, does Ploof retry the body as a form?

**Maintainer:** No. `Content-Type` selects one declared decoder before body
intake, and that decoder's failure is final for the request.

**Developer:** Does `Body.Bytes` expose gzip or HTTP chunk bytes?

**Maintainer:** No. It exposes only the content-decoded representation. Wire
coding and transfer framing remain runtime concerns.

**Developer:** Does percent-decoding allocate during a request?

**Maintainer:** No. Ploof borrows unchanged input or decodes directly into the
request's startup-allocated workspace; it never falls back to a heap.

**Developer:** Does an exhausted JSON workspace leave the request waiting?

**Maintainer:** No. Ploof sends its preallocated 503 and closes before receiving
the body; base control-slot exhaustion is handled earlier by kernel backpressure.

**Developer:** Does `Body.Text` accept `text/plain; charset=iso-8859-1`?

**Maintainer:** No. Text bodies are UTF-8 only; another declared charset receives
415 rather than being transcoded.

**Developer:** Will adding a new optional field break an older Ploof server?

**Maintainer:** Not under the standard unknown JSON field policy. The older
typed route validates and skips that field unless it explicitly selected reject
mode.

**Developer:** Can a parsed string be stored globally after the request?

**Maintainer:** No. It may borrow body chunks or JSON parse memory and expires
after middleware `after`. Transfer it into explicitly owned storage first.

**Developer:** Does `nickname: ?[]const u8` allow the member to be absent?

**Maintainer:** No. It allows `null`. Write `nickname: ?[]const u8 = null` when
both a missing member and explicit `null` are valid.

**Developer:** Can a UUID codec write a prebuilt JSON fragment directly?

**Maintainer:** No. Its codec hook emits one string through Ploof's structured
encoder, so escaping and every route JSON limit remain active.

**Developer:** Can `CreateUser` contain a password field that is skipped only
when encoded?

**Maintainer:** No. Decode into a request DTO containing the password, then
construct a separate public response DTO that has no password field.

**Developer:** Does `.omit_if_null` also omit `false` or an empty string?

**Maintainer:** No. It omits only an optional field whose value is null. Every
other value remains explicit JSON.

**Developer:** Does parsing a dynamic JSON object allocate a hash table?

**Maintainer:** No. It stores members contiguously in input order and scans them
for exact lookup. Use a typed route when repeated lookup is performance-critical.

**Developer:** Can an early file become permanent before a later multipart
field validates?

**Maintainer:** No. Durable sinks remain staged through complete body and
pre-commit response validation. The completion handler then explicitly commits
or aborts the request's upload transaction.

**Developer:** Does Ploof accept multipart bodies containing only LF line
endings because Go does?

**Maintainer:** No. HTTP multipart delimiters require CRLF. LF-only input is a
malformed request even though Go's general MIME reader tolerates it.

**Developer:** Can a file claim `multipart/mixed` and create extra upload
callbacks?

**Maintainer:** No. A route-declared file remains one opaque stream regardless
of its untrusted media type. Multiple files use repeated outer parts declared
by the route schema.

**Developer:** Can a client attach an arbitrary header to every file and make
Ploof retain it?

**Maintainer:** No. Ploof validates and counts unsupported part headers, then
discards them. Use a schema-declared field for application metadata.

**Developer:** Does an empty browser file input satisfy a required upload?

**Maintainer:** No. Its no-file marker counts toward request limits but not file
cardinality. A required file remains missing and the body receives 400.

**Developer:** Can a multipart string returned by `parseText` be retained until
completion without copying?

**Maintainer:** No. Any result borrowing the ordinary-field buffer expires with
that callback. Store an inline value or copy into explicitly bounded request
state.

**Developer:** Can a route choose an upload storage plugin by string during a
request?

**Maintainer:** Not through a framework registry. Declare one concrete sink or
write a concrete tagged-union sink when runtime backend selection is required.

**Developer:** Does `claimedMediaTypes(.{"image/png"})` prove an upload is a
PNG image?

**Maintainer:** No. It rejects a mismatched client header cheaply. Use a
format-specific streaming verifier when the actual bytes form a security
boundary.

**Developer:** Can an upload policy silently ignore a rejected file and let the
request succeed?

**Maintainer:** No. It accepts the file or rejects the request. Deliberate
disposal is an explicit sink and still counts as an admitted file.

**Developer:** Can a custom upload sink submit its own SQEs directly?

**Maintainer:** No. It declares its upload I/O requirements and returns only
those normalized requests from fixed-state pollers; Ploof owns SQEs, operation
identity, cancellation, and CQE lifetime.

**Developer:** Does closing the client connection halfway through upload commit
cancel the remaining commits?

**Maintainer:** No. Once the application chooses commit, Ploof completes the
sequential commit or compensation independently of response delivery.

**Developer:** Must every application implement an io_uring state machine to
save an upload to disk?

**Maintainer:** No. Ploof ships `FileSink`, implemented through the same public
fixed-state poll contract used by custom sinks. A minimal configuration supplies
`root` and an explicit `.buffered` or `.crash_durable` choice; the key bound,
staging mode, and file mode have safe configurable defaults.

**Developer:** Can a storage key use `../` or a symlink beneath the configured
root?

**Maintainer:** No. Key syntax rejects dot components, and `openat2` rejects
symlinks, magic links, mount crossings, and any resolution outside the root.

**Developer:** Does `FileSink` silently create a named temporary file when
`O_TMPFILE` is unsupported?

**Maintainer:** No. The default fails its startup probe with a clear error.
Named staging is an explicit mode with documented crash-orphan cleanup.

**Developer:** Does a successful buffered `FileSink` response guarantee the
file survives a power loss?

**Maintainer:** No. Select `.crash_durable` to synchronize the file and every
changed directory before response commitment.

**Developer:** Can a handler choose a built-in HTML template from a filename in
the request?

**Maintainer:** No. Each HTML template has a closed relationship with its
template view. Runtime or CMS templates must render through an external library
and enter Ploof as ordinary response bytes or a stream.

**Developer:** Does embedding JavaScript mean copying it into every HTML
response?

**Maintainer:** No. An embedded asset normally has its own generated HTTP
representation. Inlining CSS or JavaScript into a particular HTML template is
an explicit choice for that asset.

**Developer:** Can a request string be interpolated directly into an inline
script?

**Maintainer:** No. Plain template interpolation is confined to inert HTML
contexts. Browser data uses a typed JSON representation; application-owned
JavaScript remains static template or embedded-asset content.

**Developer:** Can a normal URL value be used as a script source?

**Maintainer:** No. Active resources require a compatible asset reference or a
trusted resource URL. This is a stronger decision than validating an ordinary
navigation destination.

**Developer:** Does constructing a web URL for any HTTPS host make it a safe
post-login redirect target?

**Maintainer:** No. A URL value prevents browser code injection; it does not
authorize or endorse its destination. Redirect behavior still needs an
application allowlist or server-side destination mapping.

**Developer:** Can `Url.local` accept a preassembled path containing raw
Unicode?

**Maintainer:** No. Raw URL input uses strict ASCII syntax. Give UTF-8 values to
a route or component builder, which percent-encodes them without letting data
become URL structure.

**Developer:** Can a database row choose which external script a template
loads?

**Maintainer:** No. Trusted resource URLs come only from application source or
a finite startup-validated resource table. Request-time data cannot create or
extend one.

**Developer:** How does static JavaScript receive request-specific page state?

**Maintainer:** The template emits a typed browser data block. Static
JavaScript reads its text and parses the JSON; the data is never interpolated
as executable source.

**Developer:** Can a template print sanitized rich text without escaping its
tags?

**Maintainer:** Yes, but only as trusted HTML. Runtime construction uses an
explicit unsafe assertion that the application must justify during review.

**Developer:** Can a navigation partial read the page's root view implicitly?

**Maintainer:** No. The call passes the partial's concrete template view
explicitly, so its complete data dependency is visible and checked.

**Developer:** Does a page body become trusted HTML when inserted into its
layout?

**Maintainer:** No. Layout and body templates are compiled as one closed graph,
and each keeps its own typed view and interpolation checks.

**Developer:** Does `if view.items` mean the collection is non-empty?

**Maintainer:** No. Template conditions require a boolean. Use a loop's empty
branch or expose an explicit presentation flag from Zig.

**Developer:** Can a template helper query the database for a display name?

**Maintainer:** No. Load application data in the handler. A template helper is
an immediate typed presentation transformation with no request context or I/O.

**Developer:** Will interpolating a struct print its Zig debug representation?

**Maintainer:** No. Only declared template text and scalar types render
directly. A domain type must provide a bounded text formatter or use a helper.

**Developer:** Can an application change template delimiters to coexist with a
client-side template language?

**Maintainer:** Ploof delimiters are fixed. Place static client-template text in
a `verbatim` block, where its braces are literal but its HTML is still checked.

**Developer:** Does raising a page's render limit reserve that many bytes for
every active request?

**Maintainer:** No. A finite HTML response leases shared worker response chunks
as it renders, while its route limit remains a hard output ceiling.

**Developer:** Does a finite response wait when every gzip workspace is busy?

**Maintainer:** No. It uses identity when the client permits it; otherwise the
runtime returns its bounded overload response and closes the connection.

**Developer:** Can a finite HTML template switch to streaming when its output
becomes large?

**Maintainer:** No. Raise its explicit finite bound or construct a separate
streaming response whose commitment and failure semantics are visible.

**Developer:** Can a page loop over data to generate SVG elements on the
server?

**Maintainer:** Not through the version-one template engine. Inline SVG is
static; dynamic graphics use application JavaScript or a separately produced
image representation.

**Developer:** Does Ploof infer that a source file is a full page because it
starts with a doctype?

**Maintainer:** No. The application declares a document, fragment, or layout
kind at comptime, and the source must satisfy that contract.

**Developer:** How does a template conditionally emit `disabled` without a
dynamic attribute name?

**Maintainer:** An `if` selects the complete static attribute. Both paths return
to the same between-attributes context, and the compiler checks duplicates.

**Developer:** Can a template omit `</li>` because browsers infer it?

**Maintainer:** No. Ploof templates use explicit balanced source; browser error
recovery is not part of the template language.

**Developer:** Does a new binary keep serving every asset hash from the previous
binary?

**Maintainer:** No. Each build carries its own finite asset bundle. Rolling
deployments retain older hashes at the edge or route asset requests to a
version-consistent instance.

**Developer:** Does serving an embedded stylesheet consume a gzip workspace on
every request?

**Maintainer:** No. The build produces deterministic identity and gzip
representations where compression applies. The runtime selects immutable bytes
without compression work or allocation; large range-addressable media belongs
on the general static-file path or at the edge.

**Developer:** If a static file is missing, can Ploof try another directory at
the same mount path?

**Maintainer:** No. A static mount is one deterministic route-graph owner. A
missing, hidden, or disallowed entry returns 404 instead of starting filesystem
fallback or exposing directory contents.

**Developer:** Does a reported Linux 7.1 kernel prove Ploof can start?

**Maintainer:** No. Host policy, seccomp, resources, registrations, or an active
operation can still fail. Ploof creates its real rings and exercises the
required contract before any service listener becomes ready.

**Developer:** Is `7.1.3-pikaos` a different kernel from `7.1.3` for admission?

**Maintainer:** No. Kernel policy compares the leading numeric
`major.minor.patch` tuple against a minimum. Distribution packaging suffixes do
not change that tuple, any higher release passes, and upstream release
candidates remain rejected.

**Developer:** Does the shutdown grace deadline cancel an upload after its
completion handler chose commit?

**Maintainer:** No. Grace expiry closes its transport but commit or compensation
continues. If it cannot quiesce inside the forced-cancellation window, shutdown
is reported incomplete rather than pretending durable work stopped safely.

**Developer:** Does moving access-log formatting to another thread permit that
thread to allocate per event?

**Maintainer:** No. Event records, queues, formatter scratch space, and output
batches are all reserved at startup. Both enqueue and first-party NDJSON
formatting remain allocation-free after startup.

**Developer:** Does the deterministic test reactor let a production server run
without io_uring?

**Maintainer:** No. It exists only in tests beneath a private seam and drives
the same production state machines. A real server still proves ADR 0123's
io_uring contract before becoming ready.

**Developer:** Can deterministic simulation replace real kernel and proxy
tests?

**Maintainer:** No. The same behavior is exercised through real io_uring,
loopback TCP, filesystems, Caddy, and nginx. Simulation adds controlled failure
and scheduling coverage that real tests cannot reproduce reliably.

**Developer:** Does full testing require a reported 100 percent line-coverage
score?

**Maintainer:** No. Coverage is a regression signal. Every reachable critical
state transition, invariant, boundary, error mapping, exhaustion outcome, and
injected failure edge needs a test even when a line score would hide a missing
case.

**Developer:** Can Ploof assume bytes forwarded by an edge proxy are safe?

**Maintainer:** No. Every request byte remains hostile. Trust configuration may
authorize a proxy to assert connection metadata, but it does not make HTTP,
body, path, or template-view data trustworthy.

**Developer:** Must Ploof parse an ambiguous request exactly as Caddy or nginx
does?

**Maintainer:** No. The security invariant is that a proxy chain cannot turn
one ambiguous byte stream into a hidden second request. Ploof keeps its strict
grammar, and raw-stream tests detect disagreement at request boundaries.

**Developer:** Can a fuzz crash be discarded after its immediate bug is fixed?

**Maintainer:** No. Its minimized public input becomes a deterministic security
corpus regression so later parser, SIMD, or state-machine changes cannot
reintroduce it.

**Developer:** Is ReleaseFast the production recommendation because it wins a
headline benchmark?

**Maintainer:** No. ReleaseSafe is the production and regression target.
ReleaseFast receives the same tests, fuzz families, and benchmark cases. Its
measurements expose remaining safety-check cost and guide optimization; they do
not replace safety to improve a chart.

**Developer:** Does one faster run justify replacing scalar code with SIMD or a
branchless loop?

**Maintainer:** No. Sigbench must show a repeatable improvement outside the
calibrated noise floor on representative inputs, and differential tests must
prove the replacement equivalent.

**Developer:** Can Ploof claim it beat Gin or Express using a smaller response
or more server cores?

**Maintainer:** No. Published comparisons use identical wire results, enabled
features, core budgets, and proxy topology in each framework's production mode.
They inform design and users but do not become unstable third-party CI gates.

**Developer:** Does sigbench itself generate realistic HTTP load?

**Maintainer:** No. Sigbench owns sampling, statistics, baselines, and gates.
Ploof supplies one bounded load driver for its real io_uring and deployment
cases rather than mistaking an in-process routine for an HTTP workload.

**Developer:** Does importing `ploof` also compile the deterministic test
reactor, asset compiler, and sigbench into production?

**Maintainer:** No. Production, testing, and host asset generation are separate
package surfaces, and sigbench is a lazy benchmark-only dependency.

**Developer:** Is an internal source file stable if an application finds a way
to import it directly?

**Maintainer:** No. Only documented re-exports and observable contracts form
the public API. Consumer fixtures deliberately prove that applications need no
internal path.

**Developer:** Can a `0.1.1` patch release rename a handler API because Ploof is
not yet 1.0?

**Maintainer:** No. Ploof adopts a stronger pre-1.0 rule: patches remain source
compatible, while a breaking change requires a minor release and migration
guide.

**Developer:** Does zero production dependencies prohibit sigbench, Caddy, or
nginx in the repository's development workflow?

**Maintainer:** No. Sigbench is build-time benchmark tooling, and the proxies
are external integration-test programs. None enters the production module,
application dependency graph, or binary.

**Developer:** Does Ploof need glibc, musl, or liburing to use io_uring?

**Maintainer:** No. Its production path uses Zig's Linux syscall and kernel
UAPI surface directly. CI builds and inspects a libc-free production fixture;
an application may still link libc for an unrelated dependency.

**Developer:** Can an unreviewed fork pull request run on the permanent
benchmark machine?

**Maintainer:** No. Trusted integration uses ephemeral isolated workers after
approval, and the permanent performance host accepts only trusted revisions.

**Developer:** Are Caddy and nginx the only edge proxies Ploof supports?

**Maintainer:** No. They are pinned representative deployment profiles. The
contract is strict HTTP/1.1 and configured proxy-protocol behavior, which can
be supplied by another conforming edge proxy.

**Developer:** Can a release proceed after retrying or skipping one flaky
required job?

**Maintainer:** No. It needs complete release evidence for the exact tagged
revision; a retry needs a recorded cause and an unresolved flaky result blocks
the release.

**Developer:** Will every pre-1.0 minor receive security fixes forever?

**Maintainer:** No. The newest line is supported, and the previous line receives
high and critical security backports for 90 days after its successor.
