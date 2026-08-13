INSERT INTO boards (slug, name, description, color, sort_order)
VALUES (
    'general',
    'General',
    'Ideas, improvements, and bug reports for the product.',
    'violet',
    0
)
ON CONFLICT (slug) DO NOTHING;
