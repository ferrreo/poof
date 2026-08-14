# Deploying Poof

## Host

Poof inherits Ploof's production contract:

- Linux 6.1 or newer;
- x86_64-v3 CPU;
- Zig 0.16.0 for source builds;
- required io_uring operations available through host policy/seccomp;
- ReleaseSafe binary;
- plaintext HTTP/1.1 behind a trusted TLS reverse proxy.

Build:

```sh
zig build -Doptimize=ReleaseSafe
```

The executable is `zig-out/bin/poof`.

## PostgreSQL

Create one database and role:

```sql
CREATE ROLE poof LOGIN PASSWORD 'use-a-secret-manager';
CREATE DATABASE poof OWNER poof;
```

Poof migrates on startup. Each migration is embedded into the binary,
checksummed, and applied under an advisory transaction lock. Back up PostgreSQL
before replacing a production binary.

Recommended backup:

```sh
pg_dump --format=custom --file=poof.dump "$DATABASE_URL"
pg_restore --clean --if-exists --dbname="$DATABASE_URL" poof.dump
```

Test restores separately. Never run `zig build test-integration` against this
database because the test suite intentionally resets the public schema.

## Discord

Create one Discord application and add the exact callback:

```text
https://feedback.example.com/auth/discord/callback
```

Set `DISCORD_CLIENT_ID`, `DISCORD_CLIENT_SECRET`, and
`DISCORD_REDIRECT_URI`. Poof needs only `identify`.

## RustFS image storage

Poof stores uploaded images (logo, evidence, Markdown inserts) in an
S3-compatible bucket and serves them through `GET /media/:key`. Configure:

```text
POOF_RUSTFS_ENDPOINT=https://rustfs.internal:9000
POOF_RUSTFS_REGION=us-east-1
POOF_RUSTFS_ACCESS_KEY=...
POOF_RUSTFS_SECRET_KEY=...
POOF_RUSTFS_BUCKET=poof-media
```

Production refuses to start without these. Poof creates the bucket on startup
when missing. Keep the bucket private; browsers never talk to RustFS directly.
Uploads are capped at 5 MiB and limited to PNG, JPEG, GIF, and WebP (SVG is
rejected). Local Compose includes a `rustfs` service on `127.0.0.1:9000`.

## Reverse proxy

The application binds loopback. Use `deploy/Caddyfile.example` as a baseline.
Poof trusts `X-Forwarded-*` only from loopback, so the proxy must be local or
its source trust profile must be changed deliberately in code and reviewed.

The public URL and forwarded effective origin must match exactly. A mismatch
fails browser requests with 421 rather than weakening CSRF checks.

Keep `/metrics` private. `/live` is process liveness and `/ready` transitions
with Ploof startup/drain. The MCP endpoint is `/mcp` and must never be exposed
without HTTPS.

## Service manager

Example systemd unit:

```ini
[Unit]
Description=Poof feedback server
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
User=poof
Group=poof
EnvironmentFile=/etc/poof/poof.env
ExecStart=/opt/poof/poof
Restart=on-failure
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/poof
LimitNOFILE=65536
TimeoutStopSec=40

[Install]
WantedBy=multi-user.target
```

Ploof's default graceful and forced shutdown windows total 35 seconds, so the
service manager timeout must be longer.

## Upgrade

1. Back up PostgreSQL.
2. Build the candidate with Zig 0.16.0 in ReleaseSafe.
3. Run unit and integration tests against a restored non-production database.
4. Stop the old process gracefully.
5. Start the candidate and wait for `/ready`.
6. Verify feedback, roadmap, changelog, assets, Discord callback, and one
   short-lived read-only MCP token.
7. Revoke the verification token.

Do not run old and new binaries concurrently if the new binary contains a
schema migration that is not documented as backward compatible.

## Capacity notes

Poof bounds list pages, Markdown, JSON, forms, HTML output, MCP schemas, and
tool responses. PostgreSQL calls are synchronous at the application layer; use
a bounded pool and fast indexed queries. The current Ploof handler API does not
provide suspend/resume integration for database sockets, so monitor worker and
pool saturation rather than hiding it with unbounded threads.
