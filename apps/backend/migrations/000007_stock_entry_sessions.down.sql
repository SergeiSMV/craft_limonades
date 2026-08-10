-- Откат P-FS-01: снимаем схему сессии ввода остатков.
-- Сначала строки (дочерняя таблица), затем шапка — из-за FK. Триггеры уходят вместе с таблицами.
DROP TABLE IF EXISTS stock_entry_lines;
DROP TABLE IF EXISTS stock_entry_sessions;
