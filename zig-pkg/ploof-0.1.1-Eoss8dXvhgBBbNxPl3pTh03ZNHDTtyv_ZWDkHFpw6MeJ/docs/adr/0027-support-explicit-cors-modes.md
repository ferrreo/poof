# Support explicit CORS modes

Ploof will provide first-party CORS policy at application, group, and route
scope. The default is disabled. Version one supports four modes: disabled,
allow any non-credentialed origin, allow an exact configured origin set, and
allow any credentialed origin.

Allow-any without credentials emits `Access-Control-Allow-Origin: *`.
Combining this representation with credentials is rejected at comptime because
browsers do not permit wildcard origins on credentialed responses. Exact-set
mode may enable credentials and reflects only a matched normalized origin with
`Vary: Origin`.

An exact policy declares between one and 64 origins. Ploof validates and
normalizes them at comptime, rejects equivalent duplicates, and retains parsed
descriptors in static application storage. Request matching therefore compares
parsed origins without reparsing configured strings or allocating. An exact
requested-header allowlist contains at most 64 case-insensitive names; duplicate
or invalid names also fail at comptime. These are public hard maxima, so a
policy at either maximum must compile without a caller branch-quota override.

Allow-any with credentials is an explicitly named mode that reflects each
syntactically valid request Origin, adds `Vary: Origin`, and emits
`Access-Control-Allow-Credentials: true`. This deliberately lets any website
read credentialed responses and therefore cannot be reached by toggling a
boolean on wildcard mode.

CORS controls browser response visibility; it does not block requests,
authenticate clients, authorize operations, or replace CSRF protection.
Opaque `null` origins are governed by ADR 0031. Preflight behavior is recorded
in ADR 0030.
