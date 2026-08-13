# Use flat strict query semantics

Ploof treats a query as flat form-style name/value pairs separated only by `&`.
The first `=` separates each name and value; a pair without `=` has an empty
value. Names repeated on the wire retain their value order. Percent triplets
decode to bytes, `+` decodes to space, and decoded data is not assumed to be
UTF-8 unless typed application binding requests validation.

Malformed percent escapes and raw semicolons reject the complete request with
400 rather than returning a partial query; an encoded `%3B` is ordinary data.
Brackets in an HTTP request target use `%5B` and `%5D` because raw brackets are
outside RFC URI query syntax. Their decoded spelling has no automatic map or
nesting behavior. Ploof preserves the raw query and exposes decoded names
through the same explicit multi-value and cardinality model as headers.

Typed cardinality follows ADR 0062.

The standard query limit is 1,000 ampersand-delimited segments, matching
Express's Node parser. Every segment, including an empty segment, consumes the
bound so repeated separators cannot bypass parser-work accounting. Exceeding
the limit returns 400 instead of Node's silent truncation. Applications can set
the limit at comptime up to a hard ceiling of 4,096; the request-line limit
separately bounds total query bytes.

Empty-segment and explicit empty-name behavior follows ADR 0074.

This follows Gin with Go for form-style decoding and Express 5's default simple
parser for flat repeated values. It deliberately rejects malformed or ambiguous
input instead of Go's partial result or Node's tolerant fallback, keeping
middleware and handlers on one interpretation.

Query values are never merged with form-body values; ADR 0060 defines that
source boundary.

URL-encoded bodies reuse this wire grammar under ADR 0061, with independent
body limits and failure status.

Sources: [RFC 3986 query syntax](https://www.rfc-editor.org/rfc/rfc3986.html#section-3.4),
[Go `url.ParseQuery`](https://pkg.go.dev/net/url#ParseQuery),
[Express query parser](https://expressjs.com/en/5x/api/application/#app.settings.table),
and [Node query strings](https://nodejs.org/download/release/latest-v24.x/docs/api/querystring.html).
