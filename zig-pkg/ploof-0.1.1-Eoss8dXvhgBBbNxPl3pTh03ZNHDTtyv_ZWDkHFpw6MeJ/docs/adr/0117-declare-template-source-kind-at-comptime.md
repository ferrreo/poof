# Declare template source kind at comptime

Every top-level HTML source declares one of three kinds at comptime.
`DocumentTemplate(View)` is a complete standalone document with no body slot.
`FragmentTemplate(View)` is balanced markup beginning and ending in HTML body
context. `LayoutTemplate(LayoutView)` is a complete document with ADR 0108's
single typed body slot.

A fragment may render as its own finite HTML response, fill a layout body, or
provide the structural source for a typed partial. Only a fragment can fill a
layout. It cannot contain a doctype or `html`, `head`, or `body` element, and a
document or layout cannot be inserted into another template graph as a
fragment.

The compiler never infers kind from source text. It validates the declared
starting and ending parser context and reports a kind mismatch at the Zig
declaration or composition call as well as the relevant template location.
This supports standalone pages and fragment workflows without permitting
nested documents or ambiguous parser assumptions.
