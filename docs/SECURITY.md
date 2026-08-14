# Poof security model

## Trust boundaries

Poof is one company per process and database. There is no tenant identifier and
no request-selected workspace. The primary boundaries are:

1. untrusted public HTTP input;
2. Discord-authenticated browser sessions;
3. configured administrators;
4. scoped MCP bearer tokens;
5. PostgreSQL and the local reverse proxy.

Ploof strictly parses HTTP/1.1, bounds request and response work, and rejects
ambiguous framing before application handlers run.

## Browser authentication

- Discord OAuth uses an unguessable one-time state and a separate transient
  HttpOnly cookie. Only hashes are stored in PostgreSQL.
- Return targets must be local absolute paths and cannot begin with `//`.
- Poof requests only `identify`; Discord access and refresh tokens are never
  persisted.
- Session cookies contain 256 random bits. PostgreSQL stores SHA-256 hashes,
  not plaintext. Login rotates the session and logout revokes it.
- Production cookies are Secure, HttpOnly, SameSite=Lax, and Host-prefixed
  where the runtime name can vary safely.
- Unsafe browser methods pass Ploof's signed double-submit CSRF policy and exact
  configured-origin check.

## Administrator bootstrap

Only Discord IDs in `POOF_ADMIN_DISCORD_IDS` may be promoted automatically.
Role values from OAuth, forms, MCP calls, or headers are ignored. Every admin
route checks the current database role.

## MCP tokens

Personal MCP tokens use the format `poof_<lookup>_<secret>` and contain
independent random lookup and secret material. At creation:

- plaintext is rendered once with `Cache-Control: no-store`;
- PostgreSQL receives only a short lookup prefix and an HMAC-SHA-256 digest;
- the HMAC key is the dedicated `POOF_API_TOKEN_PEPPER`;
- scopes, owner, optional expiry, revocation, and last use are stored.

Every MCP request:

- requires `Authorization: Bearer` over HTTPS;
- rejects query strings and browser Cookie headers;
- parses one canonical token and compares its digest in constant time;
- re-reads token status and the owner's current role;
- intersects role and token scope for each tool;
- validates Origin when supplied;
- applies per-token rate limits and finite query/output bounds;
- writes a sanitized automation audit event.

Mutation tools require a caller-generated idempotency key. Poof stores a request
digest and bounded prior result for 24 hours. Reuse with different arguments is
rejected. Publication and other high-impact tools require `confirm: true`.

Bearer tokens are never forwarded to Discord or another upstream service,
accepted in URL parameters, included in logs, or returned after creation.

### MCP authorization protocol

Poof deliberately implements the same static, revocable bearer-token setup
documented by UserJot because Cursor, Claude Code, Codex, and generic remote MCP
clients support custom headers. Poof does **not** claim that this is an OAuth
2.1 authorization server.

The token verifier is isolated so deployments can later place a
standards-compliant authorization server in front, with RFC 9728 protected
resource metadata, PKCE S256, RFC 8707 resource indicators, and audience-bound
access tokens. Do not bolt an unreviewed dynamic client-registration service
onto Poof.

## Rich text

Raw HTML is always escaped. Poof's bounded Markdown subset permits headings,
lists, task lists, quotes, tables, emphasis, strikethrough, fenced code, and
`http`/`https` or `/media/` links without allowing script, event attributes,
embedded HTML, or dangerous URL schemes. zhl renders escaped token spans for
recognized fenced-code languages. Checkboxes are display-only (`disabled`).

Content Security Policy further limits scripts, styles, frames, objects, forms,
images, and connections to known origins.

## PostgreSQL

All application values use PostgreSQL parameters. Multi-statement SQL is
restricted to embedded, checksummed migration files. Migrations run under a
transaction-level advisory lock and fail closed on checksum drift or unknown
future versions.

At the pinned pg.zig revision, `sslmode=verify-full` validates the certificate
chain but does not perform complete hostname verification. Prefer a local Unix
socket/private loopback, a trusted private network, or a separately verified
TLS tunnel until that upstream limitation is resolved. Never expose a
`sslmode=disable` database connection over an untrusted network.

## Secret handling

Generate independent 32-byte values:

```sh
openssl rand -hex 32 # POOF_CSRF_KEY
openssl rand -hex 32 # POOF_API_TOKEN_PEPPER
```

Do not commit `.env`, database passwords, Discord secrets, session cookies, MCP
tokens, or production backups. Rotate the token pepper by revoking all personal
tokens; existing HMAC digests cannot be verified after rotation.

## Reporting vulnerabilities

Do not disclose credentials or user data in a public issue. Report a concise
reproduction privately to the repository owner, including affected revision
and impact.
