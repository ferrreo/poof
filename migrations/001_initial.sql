CREATE TABLE schema_migrations (
    version integer PRIMARY KEY,
    name text NOT NULL,
    checksum bytea NOT NULL CHECK (octet_length(checksum) = 32),
    applied_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE users (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    discord_id text NOT NULL UNIQUE
        CHECK (discord_id ~ '^[0-9]{17,20}$'),
    username text NOT NULL CHECK (char_length(username) BETWEEN 1 AND 80),
    display_name text CHECK (display_name IS NULL OR char_length(display_name) BETWEEN 1 AND 80),
    avatar_hash text CHECK (avatar_hash IS NULL OR avatar_hash ~ '^[A-Za-z0-9_]{1,128}$'),
    role text NOT NULL DEFAULT 'member'
        CHECK (role IN ('member', 'admin')),
    disabled_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    last_login_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE sessions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    token_hash bytea NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),
    user_id bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE oauth_states (
    state_hash bytea PRIMARY KEY CHECK (octet_length(state_hash) = 32),
    cookie_hash bytea NOT NULL CHECK (octet_length(cookie_hash) = 32),
    return_to text NOT NULL CHECK (
        char_length(return_to) BETWEEN 1 AND 512
        AND left(return_to, 1) = '/'
        AND left(return_to, 2) <> '//'
    ),
    expires_at timestamptz NOT NULL,
    consumed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE boards (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    slug text NOT NULL UNIQUE CHECK (
        char_length(slug) BETWEEN 1 AND 80
        AND slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'
    ),
    name text NOT NULL UNIQUE CHECK (char_length(name) BETWEEN 1 AND 80),
    description text NOT NULL DEFAULT '' CHECK (char_length(description) <= 500),
    color text NOT NULL DEFAULT 'violet'
        CHECK (color IN ('violet', 'blue', 'green', 'amber', 'rose', 'gray')),
    sort_order integer NOT NULL DEFAULT 0,
    archived_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE issues (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    slug text NOT NULL CHECK (
        char_length(slug) BETWEEN 1 AND 180
        AND slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'
    ),
    board_id bigint NOT NULL REFERENCES boards(id) ON DELETE RESTRICT,
    author_id bigint NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    kind text NOT NULL CHECK (kind IN ('feature', 'improvement', 'bug')),
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'reviewing', 'planned', 'in_progress', 'completed', 'closed')),
    priority text NOT NULL DEFAULT 'none'
        CHECK (priority IN ('none', 'low', 'medium', 'high', 'urgent')),
    title text NOT NULL CHECK (char_length(btrim(title)) BETWEEN 5 AND 160),
    body_markdown text NOT NULL CHECK (char_length(btrim(body_markdown)) BETWEEN 20 AND 16384),
    reproduction_steps text CHECK (reproduction_steps IS NULL OR char_length(reproduction_steps) BETWEEN 1 AND 8192),
    expected_behavior text CHECK (expected_behavior IS NULL OR char_length(expected_behavior) BETWEEN 1 AND 8192),
    actual_behavior text CHECK (actual_behavior IS NULL OR char_length(actual_behavior) BETWEEN 1 AND 8192),
    environment text CHECK (environment IS NULL OR char_length(environment) BETWEEN 1 AND 8192),
    evidence_url text CHECK (
        evidence_url IS NULL
        OR (
            char_length(evidence_url) BETWEEN 1 AND 512
            AND evidence_url ~ '^https?://'
        )
    ),
    duplicate_of_id bigint REFERENCES issues(id) ON DELETE SET NULL,
    pinned boolean NOT NULL DEFAULT false,
    locked boolean NOT NULL DEFAULT false,
    completed_at timestamptz,
    closed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CHECK (duplicate_of_id IS NULL OR duplicate_of_id <> id),
    CHECK (
        kind <> 'bug'
        OR (
            reproduction_steps IS NOT NULL
            AND actual_behavior IS NOT NULL
            AND char_length(btrim(reproduction_steps)) >= 10
            AND char_length(btrim(actual_behavior)) >= 10
        )
    ),
    CHECK ((status = 'completed') = (completed_at IS NOT NULL)),
    CHECK ((status = 'closed') = (closed_at IS NOT NULL))
);

CREATE TABLE issue_votes (
    issue_id bigint NOT NULL REFERENCES issues(id) ON DELETE CASCADE,
    user_id bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (issue_id, user_id)
);

CREATE TABLE comments (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    issue_id bigint NOT NULL REFERENCES issues(id) ON DELETE CASCADE,
    author_id bigint NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    parent_id bigint REFERENCES comments(id) ON DELETE CASCADE,
    body_markdown text NOT NULL CHECK (char_length(btrim(body_markdown)) BETWEEN 1 AND 4096),
    edited_at timestamptz,
    deleted_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION enforce_comment_parent() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    parent_issue_id bigint;
    grandparent_id bigint;
BEGIN
    IF NEW.parent_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT issue_id, parent_id INTO parent_issue_id, grandparent_id
    FROM comments
    WHERE id = NEW.parent_id;

    IF NOT FOUND OR parent_issue_id <> NEW.issue_id OR grandparent_id IS NOT NULL THEN
        RAISE EXCEPTION 'comment parent must be a top-level comment on the same issue'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER comments_parent_guard
BEFORE INSERT OR UPDATE OF parent_id, issue_id ON comments
FOR EACH ROW EXECUTE FUNCTION enforce_comment_parent();

CREATE TABLE issue_events (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    issue_id bigint NOT NULL REFERENCES issues(id) ON DELETE CASCADE,
    actor_id bigint REFERENCES users(id) ON DELETE SET NULL,
    source text NOT NULL DEFAULT 'web' CHECK (source IN ('web', 'mcp', 'system')),
    event_type text NOT NULL CHECK (
        event_type IN (
            'created', 'status_changed', 'priority_changed', 'board_changed',
            'edited', 'pinned', 'unpinned', 'locked', 'unlocked',
            'duplicate_marked', 'duplicate_cleared', 'commented'
        )
    ),
    from_value text,
    to_value text,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE changelog_entries (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    slug text NOT NULL UNIQUE CHECK (
        char_length(slug) BETWEEN 1 AND 180
        AND slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'
    ),
    author_id bigint NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    title text NOT NULL CHECK (char_length(btrim(title)) BETWEEN 3 AND 160),
    summary text NOT NULL CHECK (char_length(btrim(summary)) BETWEEN 1 AND 500),
    body_markdown text NOT NULL CHECK (char_length(btrim(body_markdown)) BETWEEN 1 AND 65536),
    version text CHECK (version IS NULL OR char_length(version) BETWEEN 1 AND 64),
    tags text[] NOT NULL DEFAULT '{}',
    status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'published')),
    published_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CHECK ((status = 'published') = (published_at IS NOT NULL))
);

CREATE TABLE changelog_issue_links (
    changelog_id bigint NOT NULL REFERENCES changelog_entries(id) ON DELETE CASCADE,
    issue_id bigint NOT NULL REFERENCES issues(id) ON DELETE RESTRICT,
    sort_order integer NOT NULL DEFAULT 0,
    PRIMARY KEY (changelog_id, issue_id)
);

CREATE TABLE api_tokens (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    lookup_prefix text NOT NULL UNIQUE CHECK (lookup_prefix ~ '^poof_[A-Za-z0-9_-]{12}$'),
    token_digest bytea NOT NULL UNIQUE CHECK (octet_length(token_digest) = 32),
    label text NOT NULL CHECK (char_length(btrim(label)) BETWEEN 1 AND 80),
    scopes bigint NOT NULL CHECK (scopes BETWEEN 1 AND 63),
    expires_at timestamptz,
    revoked_at timestamptz,
    last_used_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE automation_events (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    token_id uuid REFERENCES api_tokens(id) ON DELETE SET NULL,
    owner_id bigint REFERENCES users(id) ON DELETE SET NULL,
    method text NOT NULL CHECK (char_length(method) BETWEEN 1 AND 80),
    tool_name text CHECK (tool_name IS NULL OR char_length(tool_name) BETWEEN 1 AND 100),
    target_type text CHECK (target_type IS NULL OR char_length(target_type) BETWEEN 1 AND 40),
    target_id text CHECK (target_id IS NULL OR char_length(target_id) BETWEEN 1 AND 80),
    outcome text NOT NULL CHECK (outcome IN ('success', 'error', 'denied', 'rate_limited')),
    summary text NOT NULL DEFAULT '' CHECK (char_length(summary) <= 500),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE idempotency_keys (
    token_id uuid NOT NULL REFERENCES api_tokens(id) ON DELETE CASCADE,
    tool_name text NOT NULL CHECK (char_length(tool_name) BETWEEN 1 AND 100),
    request_key text NOT NULL CHECK (char_length(request_key) BETWEEN 8 AND 128),
    request_digest bytea NOT NULL CHECK (octet_length(request_digest) = 32),
    response_body jsonb NOT NULL,
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (token_id, tool_name, request_key)
);

CREATE FUNCTION set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END
$$;

CREATE TRIGGER users_updated_at
BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER boards_updated_at
BEFORE UPDATE ON boards FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER issues_updated_at
BEFORE UPDATE ON issues FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER comments_updated_at
BEFORE UPDATE ON comments FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER changelog_entries_updated_at
BEFORE UPDATE ON changelog_entries FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX sessions_user_active_idx ON sessions (user_id, expires_at)
    WHERE revoked_at IS NULL;
CREATE INDEX sessions_expiry_idx ON sessions (expires_at);
CREATE INDEX oauth_states_expiry_idx ON oauth_states (expires_at)
    WHERE consumed_at IS NULL;
CREATE INDEX boards_active_order_idx ON boards (sort_order, id)
    WHERE archived_at IS NULL;
CREATE INDEX issues_public_order_idx ON issues (pinned DESC, created_at DESC, id DESC);
CREATE INDEX issues_status_order_idx ON issues (status, priority, created_at DESC);
CREATE INDEX issues_board_order_idx ON issues (board_id, created_at DESC);
CREATE INDEX issues_kind_order_idx ON issues (kind, created_at DESC);
CREATE INDEX issues_search_idx ON issues
    USING gin (to_tsvector('simple', title || ' ' || body_markdown));
CREATE INDEX issue_votes_user_idx ON issue_votes (user_id, created_at DESC);
CREATE INDEX comments_issue_idx ON comments (issue_id, created_at, id);
CREATE INDEX comments_author_idx ON comments (author_id, created_at DESC);
CREATE INDEX issue_events_issue_idx ON issue_events (issue_id, created_at DESC, id DESC);
CREATE INDEX changelog_public_idx ON changelog_entries (published_at DESC, id DESC)
    WHERE status = 'published';
CREATE INDEX changelog_drafts_idx ON changelog_entries (updated_at DESC)
    WHERE status = 'draft';
CREATE INDEX api_tokens_owner_idx ON api_tokens (owner_id, created_at DESC);
CREATE INDEX api_tokens_expiry_idx ON api_tokens (expires_at)
    WHERE revoked_at IS NULL;
CREATE INDEX automation_events_owner_idx
    ON automation_events (owner_id, created_at DESC, id DESC);
CREATE INDEX automation_events_token_idx
    ON automation_events (token_id, created_at DESC, id DESC);
CREATE INDEX idempotency_expiry_idx ON idempotency_keys (expires_at);
