-- Откат схемы v0. Порядок обратный: сначала таблица со ссылкой (audit_log → users),
-- затем users (вместе с ней удалится её триггер), затем функция триггера.

DROP TABLE IF EXISTS audit_log;
DROP TABLE IF EXISTS users;
DROP FUNCTION IF EXISTS set_updated_at();
