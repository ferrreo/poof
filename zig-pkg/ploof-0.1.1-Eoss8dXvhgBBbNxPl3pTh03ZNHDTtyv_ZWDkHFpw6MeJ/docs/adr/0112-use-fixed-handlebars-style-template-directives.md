# Use fixed Handlebars-style template directives

Ploof template directives use the fixed `{{ ... }}` delimiter pair. A field or
local interpolates as `{{ view.title }}` or `{{ item.name }}`. Blocks use named
Handlebars-style markers: `{{#if ...}}...{{else}}...{{/if}}`,
`{{#with ... as local}}...{{else}}...{{/with}}`, and
`{{#each ... as item, index}}...{{else}}...{{/each}}`. Named closes make a
mismatch local and produce clearer diagnostics than a generic `end` token.

`{{> name value }}` invokes a static typed partial, while
`{{ helperName args... }}` invokes an exact registered helper. The reserved
`@` namespace contains compiler-owned directives such as `{{@jsonData name
value}}` and the layout's `{{@body}}`. `{{! comment }}` is removed at comptime.
Triple braces, pipelines, arbitrary expressions, and configurable delimiter
pairs are unsupported.

Opening `{{-` removes immediately preceding HTML whitespace and closing `-}}`
removes immediately following HTML whitespace. Whitespace means ASCII tab,
line feed, form feed, carriage return, or space; nothing is trimmed implicitly.
All other source bytes remain exact.

`{{#verbatim}}...{{/verbatim}}` treats nested Ploof-looking delimiters as
literal source for client-side template text. The HTML parser still consumes
and validates those bytes, so verbatim changes directive recognition rather
than creating an unchecked raw-output region. Verbatim blocks do not nest.

Verification covers every directive, named-close mismatch, reserved-name
collision, whitespace boundary, comment, verbatim delimiter, exact source-byte
preservation, and parser fuzzing.
