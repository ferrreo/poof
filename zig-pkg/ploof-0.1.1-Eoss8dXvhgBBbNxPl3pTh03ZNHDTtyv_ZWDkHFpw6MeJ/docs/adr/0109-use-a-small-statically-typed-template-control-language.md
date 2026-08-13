# Use a small statically typed template control language

Template expressions begin from an explicitly named `view` or a lexical local,
and every field path resolves exactly at comptime. `if` accepts only `bool` and
has an optional `else`; strings, numbers, slices, and optionals have no implicit
truthiness. `with` unwraps one `?T` into a named local and may provide an empty
branch.

`each` accepts fixed arrays and slices, visits them in order, binds a named item
and optional `usize` index, and may provide an empty branch. Text and byte
arrays or slices cannot be treated accidentally as collections. Locals have
lexical scope and cannot shadow the root `view`.

Runtime control work is finite even when a loop body emits no bytes. Every
executed directive and every `each` iteration consumes one operation from a
single stack `u32`. The root template shares that counter with all partial
invocations. A layout owns one counter for its layout source, body slot, body
template, and every partial below either graph; the body's configured limit
applies when that body is rendered independently, not when composed into the
layout. Helpers do not receive or reset the counter, and their charged
directive is consumed before application helper code runs.

`render_operations_max` defaults to 1,048,576 and may be lowered per root
template or layout. The hard maximum is 67,108,864 operations. Reaching zero
before another charged operation returns the distinct finite framework error
`RenderWorkExhausted` before that operation or any of its output. This limit
exists independently of encoded bytes because nested or empty loops can do
substantial CPU work while emitting nothing.

The language has no arithmetic, comparisons, compound boolean expressions,
assignment, dynamic indexing, macros, or arbitrary function calls. Application
code computes flags and presentation values in Zig. A separately declared
comptime helper contract may perform constrained formatting but does not turn
the template into embedded Zig.

This preserves familiar conditional, optional, and loop workflows without Go
template truthiness or an engine-specific expression evaluator. Generated code
contains only statically typed field access and the control flow visible in the
template. Exact delimiter spelling and nesting limits are separate decisions.

Verification includes every accepted source type, compile-fail cases for
truthiness and unsupported collections, empty and non-empty branches, lexical
scope and shadowing, nested zero-output loops, exact operation boundaries,
shared partial and layout/body accounting, and field-path diagnostics.
