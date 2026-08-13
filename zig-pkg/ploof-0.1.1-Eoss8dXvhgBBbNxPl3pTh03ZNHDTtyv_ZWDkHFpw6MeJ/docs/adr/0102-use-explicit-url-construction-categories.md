# Use explicit URL construction categories

Ploof has no generic permissive runtime URL parser. Internal links normally use
an allocation-free `urlFor` builder over a comptime-known route, typed path
parameters, and query values. `Url.local` accepts a complete same-origin
root-relative path, query-only reference, or fragment while rejecting an
authority, scheme, control or whitespace byte, and backslash.

`Url.web` accepts a complete absolute HTTPS destination only when its policy
explicitly selects a finite host allowlist or any HTTPS host. HTTP requires a
separate opt-in. `Url.mailto` and `Url.tel` construct and encode their specific
contact destinations rather than passing a prefixed string through a generic
parser. Runtime constructors return validation errors and retain no implicit
allocator.

Dynamic protocol-relative URLs, embedded credentials, `data`, `blob`, `file`,
`javascript`, and custom schemes are unsupported. Application-authored static
template literals remain part of trusted template source for exceptional
cases. Active-resource destinations still require `AssetRef` or
`TrustedResourceUrl` under ADR 0101.

A constructed `Url` guarantees safe browser URL syntax for its declared class;
it does not establish that an external destination is trustworthy, same-origin,
or authorized for an HTTP redirect. Applications must use an allowlist or a
server-side identifier mapping when destination choice is security-sensitive.
Exact byte grammar, component limits, and storage are separate decisions.

Sources: [WHATWG URL Standard](https://url.spec.whatwg.org/),
[OWASP Unvalidated Redirects and Forwards Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Unvalidated_Redirects_and_Forwards_Cheat_Sheet.html).
