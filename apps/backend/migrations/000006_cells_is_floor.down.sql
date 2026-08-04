-- Откат P1-05: снимаем признак напольной ячейки.
ALTER TABLE cells DROP COLUMN IF EXISTS is_floor;
