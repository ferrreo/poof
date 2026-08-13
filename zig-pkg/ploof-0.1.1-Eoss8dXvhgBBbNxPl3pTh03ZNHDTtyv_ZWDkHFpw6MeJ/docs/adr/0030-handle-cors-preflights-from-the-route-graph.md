# Handle CORS preflights from the route graph

Ploof recognizes a CORS preflight only when a request is `OPTIONS` and contains
both `Origin` and `Access-Control-Request-Method`. It answers the preflight
before invoking a route handler and advertises only methods declared for the
matched path. Ordinary `OPTIONS` requests retain the HTTP method behavior from
ADR 0012.

An allowed preflight is prepared as an empty 204 Response. Requested header
names are reflected after bounded syntax, count, and size validation; a policy
may instead require an exact configured header set. The default cache duration
is 600 seconds and can be changed by policy. Responses emit every required
`Vary` field so intermediary caches cannot reuse one origin, method, or header
decision for another.

CORS permission fields must fit every selected response field-line, aggregate
head-byte, field-count, and caller-output limit. Serialization retries at most
three transactional representations: the complete permission decision,
`Vary` only, then no synthetic fields. An actual response keeps its handler
status and body while permission fields fail closed. A generated preflight
changes 204 to 403 as soon as the complete permission decision cannot fit. Each
fallback retains the largest safe `Vary` representation that fits; if even the
empty managed representation cannot serialize, the underlying capacity error
is returned. Application and enabled route profiles that cannot fit the
required preflight `Vary` line are rejected at comptime.

A denied preflight receives 403. A disallowed actual request still executes and
simply receives no CORS permission headers because CORS controls browser
visibility rather than server authorization. This keeps access control in
authentication, authorization, and CSRF policy while avoiding hand-written
preflight routes that can drift from the compile-time route graph.
