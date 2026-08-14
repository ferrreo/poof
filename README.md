# Poof

Free, open-source feedback, roadmap, changelog, and MCP software for one company.

Poof gives a product community one place to report issues, request features,
vote, discuss the roadmap, and read release notes. Teams triage that feedback in
the same application, while scoped MCP tokens let trusted AI agents work with
the exact same domain rules.

## Highlights

- **Feedback and issue reporting** — feature, improvement, and structured bug
  forms with voting, Markdown, comments, replies, boards, projects, priorities, duplicate
  tracking, and locking.
- **Automatic public roadmap** — Planned, In Progress, and recently Completed
  columns are queries over the issue tracker, never a second stale data source.
- **Connected changelog** — Markdown release notes, drafts, publication state,
  versions, and zhl-highlighted code fences.
- **Discord login** — OAuth authorization code flow, opaque hashed sessions,
  secure cookies, and configured administrator snowflakes.
- **Secure remote MCP** — Streamable HTTP, strict JSON-RPC/tool schemas, scoped
  and expiring personal tokens, HMAC digests at rest, live role checks,
  idempotent mutations, confirmations, rate limits, revocation, and audit
  events.
- **Single-company by design** — no tenants, workspaces, plans, billing,
  subscriptions, trials, quotas, or upgrade prompts.
- **Native Zig stack** — [Ploof](https://github.com/ferrreo/ploof) HTTP,
  [zhl](https://github.com/ferrreo/zhl) syntax highlighting, and PostgreSQL.

Poof is licensed under BSD-3-Clause and contains no paid feature gates.

## Requirements

- Zig **0.16.0 exactly**
- Linux 6.1+ on x86_64-v3 hardware
- PostgreSQL 13+
- A Discord application
- RustFS (or another S3-compatible store) for image uploads
- A TLS reverse proxy for production

Ploof actively checks its io_uring requirements at startup and does not fall
back to a reduced reactor.

## Quick start

1. Start PostgreSQL and RustFS:

   ```sh
   docker compose up -d postgres rustfs
   ```

2. Copy and configure the environment:

   ```sh
   cp .env.example .env
   openssl rand -hex 32
   openssl rand -hex 32
   ```

   Put the two different generated values in `POOF_CSRF_KEY` and
   `POOF_API_TOKEN_PEPPER`. Configure the Discord callback to exactly match
   `DISCORD_REDIRECT_URI`. Set the `POOF_RUSTFS_*` values to match the RustFS
   service (defaults in `.env.example` work with Compose).

3. Build and run:

   ```sh
   set -a
   . ./.env
   set +a
   zig build run
   ```

Poof applies versioned PostgreSQL migrations under an advisory lock before
accepting traffic. The development server listens on `127.0.0.1:8080` by
default.

## Discord administration

`POOF_ADMIN_DISCORD_IDS` is a comma-separated allowlist of Discord user IDs.
Any listed user becomes an administrator on login. Removing an ID does not
silently demote an existing database administrator; perform role changes
deliberately in PostgreSQL or with a future administrative maintenance command.
Production refuses to start with an empty allowlist.

Poof requests only Discord's `identify` scope. Discord access and refresh
tokens are discarded immediately after fetching the profile.

## Remote MCP

After signing in, open **Developer tokens** from your profile. Create a
least-privilege token and copy it immediately; plaintext is shown once.

```json
{
  "mcpServers": {
    "poof": {
      "url": "https://feedback.example.com/mcp",
      "headers": {
        "Authorization": "Bearer poof_REPLACE_ME"
      }
    }
  }
}
```

Poof supports finite, stateless Streamable HTTP requests for `initialize`,
`ping`, `tools/list`, and `tools/call`. The endpoint never accepts browser
cookies or query-string tokens. Mutation tools require an idempotency key;
publishing and similarly sensitive operations also require explicit
confirmation.

The bearer-token setup intentionally matches UserJot's broadly compatible
remote MCP pattern. It is not presented as a home-grown OAuth authorization
server. See [the security guide](docs/SECURITY.md) for the trust model and
future OAuth resource-server boundary, and [the MCP reference](docs/MCP.md) for
scopes, tools, and examples.

## Development

```sh
zig build fmt-check
zig build test
zig build test-integration \
  -Ddatabase-url='postgresql://poof:poof@127.0.0.1:5432/poof_test?sslmode=disable'
zig build -Doptimize=ReleaseSafe
```

`zig build test-integration` resets the `public` schema in the configured test
database. Never point it at production.

## Architecture

- Ploof owns the fixed route graph, typed body/query decoding, CSRF, response
  framing, embedded content-addressed assets, health, readiness, and metrics.
- `pg.zig` provides a bounded PostgreSQL pool. Store methods use parameters and
  transactions for cross-table invariants.
- HTML is rendered into Ploof request-owned bounded response storage. All
  dynamic text is escaped; the Markdown renderer is the only trusted rich-text
  boundary.
- zhl highlights fenced source code without a JavaScript highlighter.
- Browser state changes use session cookies plus signed double-submit CSRF.
  MCP uses a separate bearer-token verifier and never trusts browser sessions.

Detailed production setup is in [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).