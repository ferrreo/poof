CREATE TABLE projects (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    slug text NOT NULL UNIQUE CHECK (
        char_length(slug) BETWEEN 1 AND 80
        AND slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'
    ),
    name text NOT NULL UNIQUE CHECK (char_length(name) BETWEEN 1 AND 80),
    git_url text CHECK (
        git_url IS NULL
        OR (
            char_length(git_url) BETWEEN 1 AND 512
            AND git_url ~ '^https?://'
        )
    ),
    sort_order integer NOT NULL DEFAULT 0,
    archived_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER projects_updated_at
BEFORE UPDATE ON projects FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX projects_active_order_idx ON projects (sort_order, id)
    WHERE archived_at IS NULL;

ALTER TABLE issues
    ADD COLUMN project_id bigint REFERENCES projects(id) ON DELETE SET NULL;

CREATE INDEX issues_project_order_idx ON issues (project_id, created_at DESC)
    WHERE project_id IS NOT NULL;

ALTER TABLE issue_events DROP CONSTRAINT issue_events_event_type_check;
ALTER TABLE issue_events ADD CONSTRAINT issue_events_event_type_check CHECK (
    event_type IN (
        'created', 'status_changed', 'priority_changed', 'board_changed',
        'project_changed', 'edited', 'pinned', 'unpinned', 'locked', 'unlocked',
        'duplicate_marked', 'duplicate_cleared', 'commented'
    )
);
