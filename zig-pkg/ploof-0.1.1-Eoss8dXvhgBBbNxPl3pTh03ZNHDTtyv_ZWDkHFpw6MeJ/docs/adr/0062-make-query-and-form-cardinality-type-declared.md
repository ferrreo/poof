# Make query and form cardinality type-declared

Raw query and URL-encoded form access always exposes every decoded value for a
name in wire order. Typed binding then derives required cardinality from the Zig
field type rather than selecting a value by convention.

A scalar field requires exactly one occurrence; multiple occurrences reject
the input with 400. A slice receives every occurrence in wire order. A fixed
array requires exactly its declared number of occurrences. Version one does not
split comma-separated or other collection syntax inside a value.

These rules are identical for `Query(T)` and `Form(T)`. Missing-field and
present-empty conversion behavior follows ADR 0063. Field-name lookup and
conversion occur over the bounded flat pair table; no map is required to apply
cardinality.

Field-name matching follows ADR 0067.
Unknown-name handling follows ADR 0068.

Gin chooses the first repeated form value for a scalar, while Express's simple
URL-encoded parser can expose a string or an array depending on repetition.
Ploof makes the accepted shape visible in the Zig type and rejects ambiguous
scalar pollution.

Sources: [Gin 1.12 form mapping](https://github.com/gin-gonic/gin/blob/v1.12.0/binding/form_mapping.go)
and [Express `urlencoded`](https://expressjs.com/en/5x/api.html#express.urlencoded).
