# Confine plain template interpolation to inert HTML

Ploof treats template source, declared helpers, and embedded application assets
as trusted, while ordinary template-view values are untrusted text. Plain
interpolation is accepted only in HTML data, `title` and `textarea` text, and
fully quoted static-name attributes that are neither executable nor URL
contexts. The compiler selects HTML-text or attribute-value escaping; no string
flag or ordinary helper return can disable it.

Compilation rejects plain interpolation in tag or attribute names, unquoted
attributes, comments, doctypes, raw HTML, scripts, styles, event handlers,
`srcdoc`, URL-bearing attributes, and other parser-sensitive positions. Static
`script` and `style` source remains legal, and ADR 0099 assets can be emitted as
external resources or explicit inline application content. Typed asset
references are not ordinary strings.

Browser security-policy and execution-discriminator attributes are not inert.
Version one therefore requires static template source for `base href`, iframe
`allow`, `csp`, and `sandbox`, microdata URL tokens, `crossorigin`, `integrity`,
`nonce`, `referrerpolicy`, meta discriminators and security-policy content, and
script `type`, `language`, and customized built-in `is`. Link relations that
change opener isolation or resource processing and legacy document-wide URL
pivots are static-only too. This deliberately defers dynamic CSP nonces,
sandbox policies, and related values until they have narrow nominal types
rather than accepting ordinary strings.

These guarantees cover browser-native HTML and SVG semantics. Autonomous
custom elements, arbitrary `data-*` attributes, and application JavaScript can
assign URL or executable meaning to otherwise escaped text; their private
attribute contracts remain application responsibility. The browser-native
customized built-in `is` attribute is covered and static-only.

Per-request browser data requires a typed JSON representation, and dynamic URLs
require a typed URL representation; their exact contracts are separate
decisions. Version one does not accept dynamic CSS values. Applications select
static classes or data attributes unless evidence justifies a dedicated typed
CSS contract.

This is intentionally narrower than the JavaScript, CSS, and URI contextual
escaping inherited by Gin from Go `html/template`. It preserves ordinary
Gin/Express-style rendering while reducing parser complexity, runtime work, and
the set of executable contexts requiring security proofs. Verification must
include compile-fail cases for every rejected context, exhaustive escaping
vectors, adversarial Unicode and closing-tag inputs, structure-preservation
tests, and parser/encoder fuzzing.

Sources: [Go `html/template`](https://pkg.go.dev/html/template),
[OWASP Cross Site Scripting Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Cross_Site_Scripting_Prevention_Cheat_Sheet.html).
