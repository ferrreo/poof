# Skip but count empty flat segments

An empty query or URL-encoded form body contains zero segments and zero fields.
For non-empty input, leading, trailing, or adjacent ampersands create empty
segments. Each consumes the source's segment-count budget but produces no
name/value field.

A non-empty segment without an equals sign is a present name with an empty
value. An equals sign makes the name explicit even when it is empty: `=value`
produces one empty-name field with value `value`, and `=` produces one
empty-name, empty-value field. Raw access retains those fields in wire order.

An explicit empty name cannot match the non-empty metadata names permitted by
ADR 0067, so typed binding applies ADR 0068's unknown-field policy: ignore it by
default or reject it in strict mode. Skipped empty segments remain counted so
separator runs cannot bypass parser-work limits.

These rules are identical for query and URL-encoded form parsing and are tested
at empty input, every boundary separator, and the configured count ceiling.

Sources: [WHATWG URL-encoded parser](https://url.spec.whatwg.org/#application-x-www-form-urlencoded-parsing)
and [Go `url.ParseQuery`](https://pkg.go.dev/net/url#ParseQuery).
