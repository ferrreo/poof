# Use four-phase middleware

Ploof middleware may implement four explicit phases: `head`, `body`,
`response`, and `after`. Request-side `head` and `body` run in declaration
order. `head` runs after route selection but before body intake; `body` receives
bounded decoded input as a complete view or borrowed stream events. Either may
short-circuit with a typed Response.

Once a handler or short-circuit produces an ordinary or streaming result,
applicable `response` phases run in reverse declaration order before any
response bytes are committed. They may transform status, headers, media type,
finite body, or a stream's same-type producer and declared response-trailer
names. Typed producer wrappers are composed in a handler or route helper, where
their concrete result type is visible.

There is no application-wide finite-or-stream `Result` union. Such a union
would make its member types depend on middleware output while middleware
signatures depend on the union, creating a recursive type contract. Generated
code instead branches between the finite Response and the route's one concrete
`Context.StreamResponse(P)`. On a middleware chain that can reach a streaming
handler, its `response` phase uses an inferred `anytype` result parameter and is
instantiated for the finite and stream paths. Both values expose the same head
mutation surface. The phase cannot replace finite with stream, stream with
finite, or change `P`; only the generated Workspace representation erases the
producer after response middleware completes. Head and body short-circuits and
the application error mapper remain finite.

Applicable `after` phases run in reverse declaration order only after the
runtime finishes or aborts response transmission. They receive the immutable
application and transport outcome for measurement and cleanup. They cannot
replace the response, change bytes already sent, or turn a completed
transmission into another HTTP result. Runtime instrumentation records actual
write completion and failure independently of application response metadata.

Middleware state remains in the preallocated request slot through `after`.
Only middleware whose state was initialized participates while unwinding;
unused phases disappear at comptime. This preserves early rejection and typed
cross-phase state while giving ordinary and streaming responses the same clear
pre-commit transformation boundary.

Every middleware declares a concrete `State`. Non-void state has a non-failing
`init` function, invoked when traversal reaches that middleware; void state is
initialized implicitly and occupies no state bytes. The runtime records the
initialized prefix separately from the heterogeneous state tuple. A fallible
`head` may then populate request-derived fields in an already valid State.

Body input is route-typed. M3's bodyless routes use a zero-size bodyless input;
later decoder schemas replace that route input type rather than widening one
untyped value union. Application middleware wraps every admitted request,
including redirects, OPTIONS, 404, 405, and 501. Group and route middleware run
only after an actual route is selected. Parser and request-admission failures
run no application middleware. Serialization failure still invokes `after`
with an aborted transport outcome, while HEAD suppression is an explicit
successful transport outcome.

The closed graph sizes one aligned middleware-state region in the reusable
application Workspace from the largest actual route chain. A separate bounded
initialized mask controls unwind; configured graph ceilings do not reserve
state memory. M3's `Application.serve` begins at an already parsed, semantically
admitted Input. M4 owns the runtime adapter that constructs this value, so
parser and admission failures cannot enter application middleware.

The application boundary separates response preparation from transport
completion. `prepare` runs through response serialization and retains the
request Context, initialized middleware state, and immutable application
outcome in the Workspace. A successful send calls `complete`; cancellation,
disconnect, or write failure calls `abort`. Exactly one call runs applicable
`after` phases and releases the Workspace. M3's `serve` is only the synchronous
`prepare`-then-`complete` wrapper used when copied output is already the final
transport result; M4's socket adapter uses the split lifecycle.

`serve` remains finite-only. Encountering a stream returns a typed
`StreamingRequiresTransport` error without polling its producer and unwinds
through `after` as aborted. `ploof_testing` provides a separate bounded stream
collector which drives the same production preparation and producer callbacks;
there is no second streaming implementation.

The immutable outcome contains an optional final status. A present status means
a final response was selected, even if its transport later aborted. A null
status means the request ended before any final response existed. It never
substitutes `100 Continue`, a default 200, 400, 408, or a non-standard 499.

Body routes add one split inside preparation. `prepareHeadPlanned` initializes
middleware and runs only `head`; it returns either a serialized short-circuit
or the route's immutable body plan. An accepted continuation retains that exact
middleware state, route, Context, and bodyless Input in the request Workspace.
`prepareBody` materializes the decoded route type, then runs `body`, the
handler, and `response` without reinitializing middleware. The existing
`prepare` API prevalidates the decoded tag and composes both calls for
synchronous and test clients.

The Plan shallow-copies the exact Input descriptors and scalar metadata used to
create it. Planned prepare APIs therefore accept the Plan, not a second Input
that could change method, path, terminal-slash semantics, forwarding metadata,
or CORS Origin and preflight fields. The Plan does not own pointed-to bytes.
Borrowed request-head and decoded-path bytes must remain live and immutable
until the request completes or aborts because the Context and `after` phase
retain their views. The shared Date cache may update its content; the Plan binds
that view's descriptor, not a snapshot of its bytes. Request trailers arrive
later and remain outside the head Plan.

Two shallow fingerprints bind the Input descriptors, canonical actual and
routing methods, terminal-slash interpretation, planned selection, body and
finite-output plans, and feature extension. Validation happens before request
lifecycle mutation or CORS header dereference. CORS recomputes response fields
from the validated materialized selection rather than retaining borrowed field
views in the Plan. Stale or accidentally mutated plans fail with
`InvalidRoutePlan`. These fingerprints are corruption and coherence checks for
trusted in-process application code, not authentication against malicious code
that can read the implementation and write arbitrary process memory.

Content admission may refine only an unselected body plan to one decoder
already declared by that route, with that decoder's exact encoded and decoded
limits. All declaration slices, workspace layout, and other fields must remain
identical. The framework checks this relation and reseals only when the
selection changes; bodyless requests do not pay an extra reseal. Any other
change fails before middleware or handler execution.

A framework body or decoder rejection after `head` bypasses `body`, the
handler, the application error mapper, and `response`. It records the selected
built-in final status and defers `after` until that response completes or
aborts. A disconnect, timeout, or cancellation while awaiting a body runs
`after` once with null status when transport and decoder work is quiescent.

When unread body bytes might remain, the transport supplies a close-on-prepared
head policy. It affects every immediate prepared response, including generated
and bodyless results; an accepted body continuation retains the request's
original connection policy. The serialized response carries the same close
decision consumed by the driver. This prevents a `Connection: close` header
from diverging from connection reuse and prevents unread body bytes from being
interpreted as a pipelined request.

This decision supersedes ADR 0023's three-phase contract.
