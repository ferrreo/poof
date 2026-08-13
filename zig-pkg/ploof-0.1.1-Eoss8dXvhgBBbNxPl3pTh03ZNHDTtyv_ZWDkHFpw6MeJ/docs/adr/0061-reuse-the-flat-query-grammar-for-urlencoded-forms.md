# Reuse the flat query grammar for URL-encoded forms

An `application/x-www-form-urlencoded` body uses the same strict flat parser as
ADR 0039. Ampersand is the only separator, the first equals sign separates name
and value, a missing equals sign means an empty value, plus decodes to space,
and valid percent triplets decode to bytes. Repeated names retain wire order.
Brackets have no nesting semantics.

Malformed percent escapes and raw semicolons reject the complete form with 400.
Every ampersand-delimited segment, including an empty segment, consumes the
field-count budget. The standard limit is 1,000 segments, replaceable per route
at comptime up to a hard ceiling of 4,096. Exceeding it returns 413. The decoded
body-byte limit from ADR 0018 remains independent and also returns 413.

Empty-segment and explicit empty-name behavior follows ADR 0074.

The parser operates on the content-decoded body and retains decoded names and
values in request-owned bounded storage. Version one has no nested or extended
form mode. One parser and one flat multi-value model cover both query and form
syntax while ADR 0060 keeps their sources separate.

Typed cardinality follows ADR 0062.
Form charset and UTF-8 validation follow ADR 0066.

This corresponds to Express's simple URL-encoded mode and Go's form-style wire
decoding without accepting their partial or silently truncated outcomes.

Sources: [Express `urlencoded`](https://expressjs.com/en/5x/api.html#express.urlencoded)
and [Go `url.ParseQuery`](https://pkg.go.dev/net/url#ParseQuery).
