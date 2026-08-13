CREATE TABLE site_settings (
    id boolean PRIMARY KEY DEFAULT true CHECK (id),
    company_name text NOT NULL CHECK (char_length(btrim(company_name)) BETWEEN 1 AND 80),
    tagline text NOT NULL CHECK (char_length(tagline) BETWEEN 0 AND 200),
    logo_url text CHECK (
        logo_url IS NULL
        OR (
            char_length(logo_url) BETWEEN 1 AND 512
            AND logo_url ~ '^https?://'
        )
    ),
    updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO site_settings (company_name, tagline, logo_url)
VALUES (
    'Poof',
    'Share feedback, follow the roadmap, and see what shipped.',
    NULL
);

CREATE TRIGGER site_settings_updated_at
BEFORE UPDATE ON site_settings
FOR EACH ROW EXECUTE FUNCTION set_updated_at();
