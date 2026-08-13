ALTER TABLE schema_migrations
    ADD CONSTRAINT schema_migrations_positive_version CHECK (version > 0);

ALTER TABLE idempotency_keys
    ALTER COLUMN response_body DROP NOT NULL;

DROP TABLE rate_limit_events;

CREATE TABLE user_rate_buckets (
    user_id bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    action text NOT NULL,
    bucket_start bigint NOT NULL,
    request_count integer NOT NULL CHECK (request_count > 0),
    PRIMARY KEY (user_id, action, bucket_start)
);

CREATE TABLE api_rate_buckets (
    token_id uuid NOT NULL REFERENCES api_tokens(id) ON DELETE CASCADE,
    bucket_start bigint NOT NULL,
    request_count integer NOT NULL CHECK (request_count > 0),
    PRIMARY KEY (token_id, bucket_start)
);

CREATE INDEX user_rate_buckets_retention_idx
    ON user_rate_buckets (bucket_start);
CREATE INDEX api_rate_buckets_retention_idx
    ON api_rate_buckets (bucket_start);
