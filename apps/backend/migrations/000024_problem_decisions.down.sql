-- Откат P6-07-3: решения по проблемам склада.
--
-- Проблемы возвращаются открытыми; остаток, который решения успели списать или перевести,
-- остаётся как есть — откат схемы не откатывает складские факты. Задания возврата удаляются
-- вместе с видом; склад «Возврат поставщику» — только если на нём нет остатка и коробов.
DROP TABLE IF EXISTS warehouse_problem_lines;

ALTER TABLE warehouse_problems
    DROP CONSTRAINT IF EXISTS warehouse_problems_resolved_check,
    DROP CONSTRAINT IF EXISTS warehouse_problems_write_off_check,
    DROP CONSTRAINT IF EXISTS warehouse_problems_return_check;
UPDATE warehouse_problems SET status = 'open' WHERE status = 'resolved';
ALTER TABLE warehouse_problems
    DROP COLUMN IF EXISTS decision,
    DROP COLUMN IF EXISTS doc_number,
    DROP COLUMN IF EXISTS doc_date,
    DROP COLUMN IF EXISTS supplier_id,
    DROP COLUMN IF EXISTS return_task_id,
    DROP COLUMN IF EXISTS resolved_by,
    DROP COLUMN IF EXISTS resolved_at;

DELETE FROM warehouse_tasks WHERE kind = 'supplier_return';
DROP INDEX IF EXISTS warehouse_tasks_open_return_uq;
ALTER TABLE warehouse_tasks
    DROP CONSTRAINT IF EXISTS warehouse_tasks_supplier_check,
    DROP COLUMN IF EXISTS supplier_id,
    DROP CONSTRAINT IF EXISTS warehouse_tasks_kind_check;
ALTER TABLE warehouse_tasks
    ADD CONSTRAINT warehouse_tasks_kind_check CHECK (kind IN ('putaway'));

DELETE FROM internal_warehouses w
WHERE w.system_role = 'supplier_return'
  AND NOT EXISTS (SELECT 1 FROM stock s WHERE s.internal_warehouse_id = w.id)
  AND NOT EXISTS (SELECT 1 FROM load_units lu WHERE lu.internal_warehouse_id = w.id)
  AND NOT EXISTS (SELECT 1 FROM movement_lines l WHERE l.internal_warehouse_id = w.id);
ALTER TABLE internal_warehouses DROP COLUMN IF EXISTS system_role;
