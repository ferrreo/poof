# Use strict bounded HTML template source

Template source must be valid UTF-8 without a byte-order mark or NUL. A
document or layout begins immediately with exact `<!doctype html>` and contains
one ordered `html`, `head`, and `body`. Every non-void HTML element has an
explicit correctly nested end tag; void elements have none. HTML self-closing
syntax, omitted ends, misnesting, malformed declarations, and malformed comment
forms are compile errors. ADR 0116 retains SVG self-closing syntax inside its
static foreign subtree.

Every valued HTML attribute uses single or double quotes. Bare syntax is
accepted only for the standard boolean-attribute table. Duplicate attributes
are rejected under ASCII-case-insensitive name comparison. The compiler
preserves tag, attribute, text, and line-ending source bytes while comparing
HTML names case-insensitively. Properly named custom elements remain valid.

The parser rejects lexical constructs and known implicit-close or
foster-parenting forms that would require browser recovery. It validates source
balance, template kinds, tokenizer contexts, dynamic placements, and the small
data-driven structural rules needed by Ploof. It is not a complete HTML
content-model, accessibility, or style validator.

The standard `TemplateSourceProfile` permits 256 KiB per source, 2 MiB of source
across one composed graph, 128 HTML element levels, 32 template control levels,
32 partial-call levels, 16,384 directives, 16 field-path components, and eight
helper arguments. An application may replace any value at comptime, but every
value remains finite and participates in checked arithmetic.

Compiler work has separate non-configurable hard limits of 4,096 declared
partial nodes, including registered partial configurations that are never
called, and 16,384 expanded reachable partial-call edges. Edge validation
recursively expands repeated call sites; diagnostic `PLOOF-E4028` rejects the
first graph that crosses the expanded edge limit. These compiler bounds are
independent of ADR 0109's configurable runtime render-operation counter.

Every source or limit failure reports the graph, file, line, column, actual
value, and configured limit where applicable. Verification includes boundary
tests for each limit, void and boolean tables, duplicate casing, malformed and
repair-dependent HTML corpora, custom elements, exact-byte preservation, and
tokenizer, stack, and limit fuzzing.

Source: [HTML parsing](https://html.spec.whatwg.org/multipage/parsing.html).
