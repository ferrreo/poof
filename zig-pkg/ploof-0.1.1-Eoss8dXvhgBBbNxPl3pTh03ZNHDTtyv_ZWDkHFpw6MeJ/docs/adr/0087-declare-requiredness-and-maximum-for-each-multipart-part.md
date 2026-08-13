# Declare requiredness and maximum for each multipart part

Every multipart schema entry declares whether at least one admitted value is
required and a finite maximum count. Public shorthands express the four common
shapes: exactly one, zero or one, zero to a maximum, and one to a maximum. Ploof
version one does not add arbitrary minimum counts above one; applications can
apply such business rules during completion.

Parts can arrive in any order, and callbacks preserve their global wire order.
An occurrence above the entry's declared maximum receives 400 as a schema-shape
error immediately after its headers identify it. Exceeding a route-wide part or
file count from ADR 0021 remains 413 as a resource-limit error.

At the closing boundary, any entry marked required with no admitted occurrence
receives 400 before the completion handler. An ADR 0079 empty browser file marker
consumes part and byte limits but does not satisfy required file cardinality.
Unknown discarded parts under ADR 0076 never satisfy a declaration.

A rejected declared file fails the whole request rather than becoming absent;
ADR 0091 prohibits policy-driven silent skips.

Applications needing a custom response such as 422 declare the entry optional
and validate its presence in the completion handler. This keeps structural
multipart validation deterministic while leaving domain validation under
application control.

The generated route stores only bounded per-entry counters. Requiredness and
maximum values are validated at comptime against the route's multipart limits
profile.
