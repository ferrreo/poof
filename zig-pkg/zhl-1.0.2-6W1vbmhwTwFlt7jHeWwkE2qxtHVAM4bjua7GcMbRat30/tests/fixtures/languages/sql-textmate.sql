-- line comment
SELECT count(*) AS total
FROM users
WHERE id = 42
  AND name = 'O''Reilly'
  AND active = TRUE;

/* outer /* inner */ still */
INSERT INTO users(name, score)
VALUES ("Ada", 3.14);

CREATE TABLE logs (
  id INTEGER PRIMARY KEY,
  body TEXT NOT NULL
);
