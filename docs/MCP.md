# Poof MCP

Endpoint:

```text
POST https://your-poof.example/mcp
Authorization: Bearer poof_…
Content-Type: application/json
Accept: application/json
```

Poof supports the widely deployed `2025-06-18` Streamable HTTP protocol,
finite JSON responses, and the methods `initialize`,
`notifications/initialized`, `ping`, `tools/list`, and `tools/call`. It does
not advertise the incompatible stateless 2026 protocol until that separate
transport is fully implemented.

## Scopes

| Scope | Capability |
| --- | --- |
| `poof:read` | Overview, boards, projects, feedback, roadmap, changelog |
| `issues:write` | Create issues and add/remove the owner’s vote |
| `comments:write` | Add comments and one-level replies |
| `admin:issues` | Status, priority, board, project, pin, lock, duplicate triage |
| `admin:boards` | Create and archive boards and projects |
| `admin:changelog` | Create drafts and publish/revert changelogs |

Admin scopes require the token owner to still be an administrator. Demotion
takes effect on the next request.

## Tools

- `poof_get_overview`
- `poof_list_boards`
- `poof_list_projects`
- `poof_list_issues`
- `poof_get_issue`
- `poof_get_roadmap`
- `poof_list_changelogs`
- `poof_create_issue`
- `poof_set_vote`
- `poof_add_comment`
- `poof_update_issue`
- `poof_create_board`
- `poof_update_board`
- `poof_archive_board`
- `poof_create_project`
- `poof_update_project`
- `poof_archive_project`
- `poof_create_changelog`
- `poof_update_changelog`
- `poof_publish_changelog`

Call `tools/list` for authoritative strict JSON Schemas. Unknown properties are
rejected.

## Safe mutations

Every mutation requires an `idempotency_key` of 8–128 characters. Retrying the
same tool with the same key and arguments returns the saved result. Reusing the
key with different arguments returns an error.

Poof reserves a mutation key before execution so concurrent retries cannot run
twice. If the process dies after the database mutation but before recording
the result, the reservation becomes an explicit “outcome unknown” state after
five minutes. It is never silently reclaimed; inspect the resource with read
tools before deciding whether to use a new key.

Publication requires `"confirm": true`. MCP intentionally exposes no hard
delete or role-management tool.

## Example

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "poof_list_issues",
    "arguments": {
      "status": "planned",
      "limit": 20
    }
  }
}
```

Tokens are secrets. Never place them in a URL, prompt, repository, browser
local storage, or issue body. Revoke a token immediately if it may have been
copied into logs or chat history.
