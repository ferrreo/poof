# Use direct statically typed template helpers

Each template helper has an exact comptime-registered name mapped to one
concrete Zig function. A call receives only typed fields from the current view
or lexical locals. Its signature cannot receive a request, application context,
allocator, writer, `anyopaque`, runtime function pointer, or registry handle.
The compiler emits a direct call that can normally inline.

Helper parameters are transitively read-only presentation data. Mutable,
volatile, and non-generic-address-space pointers and slices are rejected,
including when nested in another value. Ordinary const pointers and slices
remain valid when their child graph carries no framework, I/O, allocator,
registry, erased, or function capability. This is intentionally stricter than
merely banning the named top-level types and keeps helpers deterministic
without copying ordinary immutable view models or admitting MMIO.

A helper may return a supported scalar, borrowed text, bounded inline text,
`Url`, `AssetRef`, or explicitly dangerous `TrustedHtml`. Ordinary text remains
subject to the interpolation context's escaping, and only a nominal return type
changes placement rules. Results are consumed immediately and create no
retained allocation.

A helper may return a closed error union; those errors join the route's
comptime-known error set and reach its central mapper before response
commitment. `anyerror` is rejected. Helper and formatter error names must be
disjoint from the complete framework render and response-chunk error set;
otherwise Zig's global error identity could make a framework failure enter the
application mapper. Helpers cannot choose templates, layouts, partial names,
attributes, or control-flow conditions.

The contract forbids I/O and global mutation, although Zig cannot prove the
absence of hidden global side effects. Database access, substantial work, and
ordinary application failures belong in the handler. Helpers are limited to
small deterministic presentation transformations, not a runtime extension
system.

Verification covers signature rejection, exact argument and return typing,
closed-error propagation, escape preservation, nominal safe types, direct-call
code generation, and zero hot-path allocation.
