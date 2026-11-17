-- Откат P1-01-1.
-- Внимание: чтобы вернуть NOT NULL на login, сначала удаляем учётки без бейджа
-- (admin по username) - иначе SET NOT NULL упадёт на NULL-логинах.
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_login_xor_username;
DELETE FROM users WHERE login IS NULL;
ALTER TABLE users DROP COLUMN IF EXISTS username;
ALTER TABLE users ALTER COLUMN login SET NOT NULL;
