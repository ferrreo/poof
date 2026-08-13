# Require public origins only when needed

Canonical public origins are optional for ordinary Ploof servers and public
APIs. A feature that makes an origin-sensitive security decision, including
first-party CSRF middleware, requires a non-empty startup configuration. This
keeps Express-like deployment flexibility without letting a security feature
guess its trust boundary.

Each canonical origin is an exact normalized scheme, host, and effective port.
The default maximum is eight and can be changed at comptime. Runtime request or
forwarded metadata may select an entry but can never add to or widen the set.
When canonical-origin enforcement is active, a request host outside the set
receives 421; otherwise a syntactically valid host remains request metadata.

CSRF browser-source origins are a separate exact set. By default CSRF uses the
canonical public origins for both effective-host and source checks, preserving
the simple same-origin configuration. An application with a separate browser
origin provides `source_origins`; that set replaces the source allowlist but
does not widen accepted effective hosts. This permits a credentialed
`app.example` frontend to call `api.example` without accepting `app.example`
as the API deployment origin.

CORS source-origin policy remains separate from both sets. A public API may
enable wildcard CORS without declaring its own public origin. Canonical origins
do not participate in route selection.
