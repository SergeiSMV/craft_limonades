-- Откат P10-01. Остаток пересчёт до закрытия не меняет (корректировка - P10-03), поэтому уходят
-- только документы пересчёта и их задания.

DELETE FROM warehouse_tasks WHERE kind = 'stocktake';
DROP INDEX IF EXISTS warehouse_tasks_stocktake_uq;
ALTER TABLE warehouse_tasks DROP CONSTRAINT IF EXISTS warehouse_tasks_stocktake_kind;
ALTER TABLE warehouse_tasks DROP COLUMN IF EXISTS stocktake_id;
ALTER TABLE warehouse_tasks DROP CONSTRAINT warehouse_tasks_kind_check;
ALTER TABLE warehouse_tasks
    ADD CONSTRAINT warehouse_tasks_kind_check CHECK (kind IN ('putaway','supplier_return'));

DROP TABLE IF EXISTS stocktake_marks;
DROP TABLE IF EXISTS stocktake_lines;
DROP TABLE IF EXISTS stocktake_cells;
DROP TABLE IF EXISTS stocktake_scope;
DROP TABLE IF EXISTS stocktakes;
