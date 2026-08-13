# Allow only static inline SVG

Ploof version one permits balanced static inline SVG in template source for
icons and illustrations. Standard graphics elements, self-closing SVG elements,
and static `title` and `desc` text are accepted. The compiler preserves the
source and validates the foreign subtree's lexical structure.

Every Ploof interpolation, helper, partial call, control block, browser data
block, and other directive inside an SVG subtree fails at comptime. SVG
`script`, `style`, `foreignObject`, and other HTML-integration content are also
rejected. Inline MathML is unsupported in version one.

Dynamic graphics use application-owned JavaScript after page load or a
separately produced image asset. A media-compatible SVG `AssetRef` may appear
in an image context; active embedding requires `TrustedResourceUrl` under ADR
0101. Ploof does not attempt SVG sanitization or a second contextual-escaping
model.

This supports common static icons without admitting SVG's executable scripts,
resource attributes, animation, event, and HTML-integration semantics into the
template type system. Verification covers nesting, self-closing elements,
title and description text, every rejected directive, forbidden integration
elements, boundary confusion, and foreign-content parser fuzzing.

Sources: [SVG scripting](https://www.w3.org/TR/SVG/interact.html),
[SVG `foreignObject`](https://www.w3.org/TR/SVG2/embedded.html#ForeignObjectElement),
[HTML foreign-content parsing](https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-inforeign).
