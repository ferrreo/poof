# Require control blocks to preserve HTML context

Every template control block must leave each possible branch and loop
iteration in the same HTML parser context in which the block began. `if` and
`with` may wrap complete balanced body fragments or conditionally emit complete
statically named attributes between other attributes. Attribute names, equals
signs, quotes, and other structural bytes remain literal template source.

The compiler rejects any possible duplicate between unconditional attributes
and attributes emitted by a conditional path. `each` cannot run in the
between-attributes context because repetition could create duplicate fields.
Partials remain complete body fragments under ADR 0107 and cannot become an
attribute-spread mechanism.

`if`, `with`, and `each` may run inside one fully quoted inert attribute value,
for example to build a class list, provided every path remains within that
value. They cannot cross a quote or tag boundary or leave a comment, URL,
script, style, raw-text, or other restricted context unfinished.

This supports conditional boolean and optional attributes without admitting
dynamic names or a generic attribute map. Context equivalence and duplicate
sets are computed at comptime; runtime code executes only the selected static
emission path.

Verification covers conditional boolean and valued attributes, nested paths,
duplicate detection across branches, loops in values, every forbidden parser-
state transition, and context-analysis fuzzing.
