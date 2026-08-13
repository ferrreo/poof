# Ignore unknown flat fields by default

Typed query and URL-encoded form binding ignores decoded names absent from the
destination's flat field schema by default. An individual binder or route can
select a comptime `.reject` policy, in which case any unknown occurrence rejects
the input with a safe 400 before handler entry.

Ignoring affects only destination construction. Unknown segments still consume
the field-count and byte budgets and must satisfy the complete flat wire
grammar. URL-encoded form names and values also remain subject to ADR 0066's
UTF-8 validation. Repeated unknown names consume the budget once per occurrence.

Ploof does not materialize ignored values in a hidden extras map. A handler that
needs undeclared input requests the explicit raw query or form collection. The
policy applies after exact and renamed fields from ADR 0067 have been resolved.

Default ignoring supports additive clients and matches ordinary Gin struct
binding. Strict endpoints retain a generated closed-schema option without a
runtime parser switch.

Source: [Gin 1.12 form mapping](https://github.com/gin-gonic/gin/blob/v1.12.0/binding/form_mapping.go).
