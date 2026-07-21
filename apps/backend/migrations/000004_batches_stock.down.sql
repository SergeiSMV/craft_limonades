-- Откат P1-02. Обратный FK-порядок: сначала stock (→batches, →cells), затем batches (→goods).
-- Триггеры и индексы удаляются вместе с таблицами.
DROP TABLE IF EXISTS stock;
DROP TABLE IF EXISTS batches;
