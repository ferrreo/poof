-- admin_issues | admin_boards | admin_changelog = bits 3, 4, 5
-- member-safe bits: read | issues_write | comments_write = bits 0, 1, 2

UPDATE api_tokens AS t
SET scopes = GREATEST(t.scopes & 7, 1)
FROM users AS u
WHERE u.id = t.owner_id
  AND u.role <> 'admin'
  AND (t.scopes & 56) <> 0;

CREATE FUNCTION poof_api_token_admin_scopes() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF (NEW.scopes & 56) <> 0 THEN
        IF NOT EXISTS (
            SELECT 1 FROM users
            WHERE id = NEW.owner_id
              AND role = 'admin'
              AND disabled_at IS NULL
        ) THEN
            RAISE EXCEPTION 'admin MCP scopes require an admin owner'
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER api_tokens_admin_scopes
BEFORE INSERT OR UPDATE OF owner_id, scopes ON api_tokens
FOR EACH ROW EXECUTE FUNCTION poof_api_token_admin_scopes();

CREATE FUNCTION poof_strip_admin_scopes_on_demotion() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.role <> 'admin' THEN
        UPDATE api_tokens
        SET scopes = GREATEST(scopes & 7, 1)
        WHERE owner_id = NEW.id
          AND revoked_at IS NULL
          AND (scopes & 56) <> 0;
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER users_strip_admin_token_scopes
AFTER UPDATE OF role ON users
FOR EACH ROW
WHEN (OLD.role = 'admin' AND NEW.role <> 'admin')
EXECUTE FUNCTION poof_strip_admin_scopes_on_demotion();
