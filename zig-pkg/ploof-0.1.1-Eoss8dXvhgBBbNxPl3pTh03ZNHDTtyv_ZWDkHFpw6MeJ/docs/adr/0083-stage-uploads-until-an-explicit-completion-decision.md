# Stage uploads until an explicit completion decision

A durable multipart sink stages data during `begin`, bounded chunk writes, and
`finish`; none of those operations makes an upload permanent. After the final
boundary and all route schema, cardinality, limit, and body-phase checks pass,
the completion handler receives the staged upload summaries and returns either
`.commit(response)` or `.abort(response)`. An application failure implies
abort.

The generated `Summaries` struct has one field per schema-declared file. Every
field is a fixed typed `SummaryView` in occurrence order, including declarations
whose maximum is one. The view borrows request workspace through completion and
contains a pointer plus fitting length; it allocates and copies no summaries.

Ploof finishes response construction and every applicable `response`
middleware phase before applying that decision. For `.commit`, it commits each
staged sink before committing response bytes. For `.abort`, it cleans up each
begun sink before committing the selected response. A parsing, framing, limit,
sink, application, or pre-commit response failure aborts begun sinks in reverse
start order.

The sink owns its staging and cleanup mechanism; Ploof does not create an
implicit temporary file. Abort must be safe after an incomplete commit attempt.
If one of several independent sink commits fails, Ploof requests compensating
cleanup and reports the failure, but cannot promise atomic commitment across
filesystems, object stores, databases, or other independent destinations.

Each sink is a concrete comptime-known type with fixed request-local state under
ADR 0089.
Any ADR 0090 streaming content verifier must succeed before commit.
Asynchronous lifecycle work follows the ADR 0092 poll contract.

Once every upload has committed, a later response-transmission or streaming
producer failure does not roll it back. Such failures occur after the
application's explicit durable decision and may be impossible to distinguish
from a response the client received.

Commit order, compensation, cleanup failures, and disconnect behavior follow
ADR 0093.
The first-party filesystem implementation follows ADR 0094.

This adds one visible decision to each multipart completion handler. It prevents
a malformed later part, failed business rule, or failed pre-commit response
from silently orphaning an earlier streamed file.
