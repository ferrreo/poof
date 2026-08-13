# Use separate JSON request and response types

Version one has no request-only, response-only, or unconditional directional
skip flags in JSON field metadata. A typed wire struct describes every field it
declares in both directions. When an endpoint accepts and returns different
data, the application defines separate request and response structs and
explicitly constructs the response value.

This keeps passwords, credentials, and internal state out of response types
instead of relying on a serializer flag at the point of exposure. It also keeps
field metadata and generated codecs small, makes each HTTP contract readable as
a Zig type, and adds no runtime work. Whole-type custom codec hooks remain
available under ADR 0056 but are not the mechanism for hiding sensitive
fields.

Conditional output omission follows ADR 0058; it does not add directional
membership to a struct. Applications that genuinely share an identical request
and response shape can reuse one type.

This is the typed equivalent of constructing a response object in Express and
matches common Gin practice of separating binding and public response structs.

Sources: [Gin binding documentation](https://gin-gonic.com/en/docs/examples/binding-and-validation/)
and [Express JSON response](https://expressjs.com/en/5x/api.html#res.json).
