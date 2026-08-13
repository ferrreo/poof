CREATE TABLE rate_limit_events (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    action text NOT NULL CHECK (
        action IN ('issue_create', 'comment_create', 'vote_change', 'token_create')
    ),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX rate_limit_events_lookup_idx
    ON rate_limit_events (user_id, action, created_at DESC);
