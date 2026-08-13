# Make duplicate header handling explicit

Ploof will preserve ordinary request field lines in arrival order. A
case-insensitive lookup returns a borrowed multi-value view rather than a
single string. That view provides explicit `one`, `first`, and ordered iteration
operations; typed parsers for list-valued fields and cookies apply their own
combination grammar without allocating a joined value. Ploof will not provide
a generic `get` operation that silently selects or combines duplicates.

Framing fields and fields owned by a first-party protocol or security policy
retain their stricter validation before application code runs. This API is
deliberately more explicit than Go's `Header.Get`, which selects the first
stored value, and Node's primary header view, which applies name-specific
discarding and joining. Both stacks also expose plural or raw representations,
so Ploof keeps familiar capability while making cardinality visible in typed
Zig code.

Ploof keeps the strictly validated request-head bytes unchanged through the
complete request lifecycle, including middleware `after` phases. Normal lookup
is case-insensitive and returns byte slices with surrounding optional whitespace
removed while preserving every interior byte; values are not assumed to be
UTF-8. Explicit raw iteration exposes original field-name casing and untrimmed
values in wire order. These borrowed views become invalid only when the request
slot is reused, avoiding normalization copies while retaining Node-like raw
inspection when an application deliberately requests it.

Sources: [Go `http.Header`](https://pkg.go.dev/net/http#Header) and
[Node `message.headers`](https://nodejs.org/download/release/latest-v24.x/docs/api/http.html#messageheaders).
