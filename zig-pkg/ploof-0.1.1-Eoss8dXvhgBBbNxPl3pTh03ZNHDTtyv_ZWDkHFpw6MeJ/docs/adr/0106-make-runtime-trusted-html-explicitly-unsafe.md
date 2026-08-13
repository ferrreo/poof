# Make runtime trusted HTML explicitly unsafe

`TrustedHtml` is the only value that bypasses plain interpolation escaping, and
it is accepted only in normal HTML body data context. It cannot enter an
attribute, `title`, `textarea`, script, style, comment, or another parser state.
There is no triple-brace syntax, raw-output flag, implicit string conversion,
or ordinary helper return that gains this behavior.

`TrustedHtml.literal` takes a comptime fragment. The template parser verifies
valid UTF-8, balanced element structure, and a return to neutral HTML data state
before compilation succeeds. Static reusable markup should normally remain a
partial, but this constructor supports concrete helpers and generated fragments
without weakening runtime types.

`TrustedHtml.unsafeAssumeSanitized` is the sole runtime constructor. It borrows
the supplied bytes without parsing, copying, or allocating and expires with
their render lifetime. Its caller asserts that a dedicated sanitizer or other
application-controlled process produced valid UTF-8, removed attacker-
executable content, balanced the fragment, and preserved its insertion context.
Misuse can cause XSS; the unsafe name makes every trust boundary searchable and
reviewable.

Ploof version one does not ship a general HTML sanitizer. Sanitizer policies,
HTML dialect evolution, URL policies, and mutation-XSS behavior form a large
independent security surface. Applications needing user-authored rich text use
a dedicated sanitizer and cross the explicit unsafe boundary after it succeeds.

Verification ensures every ordinary value remains escaped, every forbidden
placement fails at comptime, literal fragments preserve context, and only the
nominal type can emit unescaped markup.

Source: [Go `html/template.HTML`](https://pkg.go.dev/html/template#HTML).
