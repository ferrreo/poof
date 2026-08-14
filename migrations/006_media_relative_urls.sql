DO $$
DECLARE
    constraint_name text;
BEGIN
    SELECT con.conname INTO constraint_name
    FROM pg_constraint con
    JOIN pg_attribute att
      ON att.attrelid = con.conrelid
     AND att.attnum = ANY (con.conkey)
    WHERE con.conrelid = 'issues'::regclass
      AND con.contype = 'c'
      AND att.attname = 'evidence_url'
      AND array_length(con.conkey, 1) = 1;
    IF constraint_name IS NOT NULL THEN
        EXECUTE format('ALTER TABLE issues DROP CONSTRAINT %I', constraint_name);
    END IF;

    SELECT con.conname INTO constraint_name
    FROM pg_constraint con
    JOIN pg_attribute att
      ON att.attrelid = con.conrelid
     AND att.attnum = ANY (con.conkey)
    WHERE con.conrelid = 'site_settings'::regclass
      AND con.contype = 'c'
      AND att.attname = 'logo_url'
      AND array_length(con.conkey, 1) = 1;
    IF constraint_name IS NOT NULL THEN
        EXECUTE format('ALTER TABLE site_settings DROP CONSTRAINT %I', constraint_name);
    END IF;
END $$;

ALTER TABLE issues ADD CONSTRAINT issues_evidence_url_check CHECK (
    evidence_url IS NULL
    OR (
        char_length(evidence_url) BETWEEN 1 AND 512
        AND (
            evidence_url ~ '^https?://'
            OR evidence_url ~ '^/media/[A-Za-z0-9][A-Za-z0-9.-]*$'
        )
    )
);

ALTER TABLE site_settings ADD CONSTRAINT site_settings_logo_url_check CHECK (
    logo_url IS NULL
    OR (
        char_length(logo_url) BETWEEN 1 AND 512
        AND (
            logo_url ~ '^https?://'
            OR logo_url ~ '^/media/[A-Za-z0-9][A-Za-z0-9.-]*$'
        )
    )
);
