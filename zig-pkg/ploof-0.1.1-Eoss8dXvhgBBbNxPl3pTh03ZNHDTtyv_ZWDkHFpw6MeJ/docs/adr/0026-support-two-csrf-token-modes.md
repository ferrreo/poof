# Support two CSRF token modes

Every Ploof CSRF policy will explicitly select either synchronizer or signed
double-submit token mode. There is no inferred default and no naive
double-submit implementation.

Synchronizer mode uses one cryptographically random 32-byte token per login
session, loaded and stored through typed application callbacks. It rotates on
login and logout. Its wire value is exactly 43 bytes of canonical unpadded
base64url. Submitted values are decoded strictly and compared in constant time.

Signed double-submit mode uses HMAC-SHA-256 with a fixed Ploof domain separator
and binds the token to a random 32-byte per-login value such as a session nonce
or a suitably random JWT identifier. User ID, email, and other stable or
personally identifying values are invalid bindings. The raw token is one-byte
format version, one-byte key identifier, 32-byte nonce, and 32-byte MAC; its
wire value is exactly 88 bytes of canonical unpadded base64url. The submitted
token, cookie token, and MAC are validated without timing-dependent equality.

Signed mode uses a startup keyring containing at most one active and one
previous 256-bit CSRF-only key. New tokens use the active key; the previous key
is retained for the maximum session lifetime or removed with intentional
session invalidation after compromise. Missing mode or binding callbacks are
compile errors; malformed or missing runtime key material prevents startup with
an actionable error.

Ploof receives random token, nonce, and login-binding bytes from typed
application code. It does not hide a request-path random source or derive a
binding from stable identity data. Signed cookie helpers emit a host-only,
Secure, HttpOnly, SameSite cookie with `Path=/`; general cookie policy remains
application-owned.

Signed hidden-input helpers accept only canonical tokens whose MAC verifies
against the current login binding and keyring. Attribute values are escaped as
defense in depth. Cookie helpers apply the `__Host-` and `__Secure-` prefix
requirements to every ASCII case variant, matching user-agent enforcement.
Path accepts only RFC 10025 `av-octet` bytes and must begin with `/`.

Both modes require an `origins` provider for canonical effective deployment
origins. An optional `source_origins` provider supplies a separate exact
Origin or Referer allowlist. When omitted it aliases `origins`; when present it
replaces the source allowlist, so applications include their same-origin entry
explicitly when they need both same-origin and cross-origin browser clients.
The two providers may use different bounded `OriginSet` types.

CSRF callbacks are deliberately infallible and perform no I/O. They access
session identity already loaded into application state or request context by
earlier middleware. Any fallible backing-store operation must finish before the
CSRF policy runs.

Each token mode accepts only its documented configuration fields, so a typo is
a compile error rather than a silently ignored default. Configured form names
accept the standard HTTP token alphabet. Hidden-input helpers HTML-escape `&`
while preserving the field identity that the browser submits.
