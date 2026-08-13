# Require complete typed partial templates

Every partial template has a comptime-known name and source file, declares one
concrete view type, and receives that view explicitly at each call. It cannot
read caller locals, a root object, request context, or a string-keyed ambient
scope. The compiler checks each call and reports type or field failures at both
the call site and partial source location.

A partial must be a complete balanced fragment that begins and ends in neutral
HTML body data context. It cannot inject an attribute sequence, open an element
closed by its caller, close a caller element, or be called from an incompatible
parser context. These restrictions keep interpolation escaping and trusted-HTML
placement locally provable.

The static partial graph must be acyclic. A typed loop may invoke a partial any
number of times within the route's render bound, but a partial cannot call
itself directly or indirectly in version one. Recursive application trees must
be flattened or handled by an explicit bounded application renderer.

This costs some view plumbing compared with ambient-scope Gin or Express
engines, but removes hidden data dependencies, dynamic lookup, recursion depth,
and cross-file parser-state coupling. Layout composition remains a distinct
contract rather than a special partial convention.
