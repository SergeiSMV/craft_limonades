-- P10-03: откат подсчёта ячейки пересчёта.
--
-- Проблемы «не найдено» и строки журнала пересчёта откат удаляет: без причины и источника
-- они не проходят прежние ограничения. Склад «Не найдено» снимается, только если на нём нет
-- остатка и коробов: иначе откат стёр бы учёт.
ALTER TABLE stocktake_marks DROP COLUMN problem_id;
ALTER TABLE stocktake_lines DROP COLUMN problem_id;

DELETE FROM placements WHERE source = 'stocktake';
ALTER TABLE placements DROP COLUMN stocktake_cell_id;
ALTER TABLE placements DROP CONSTRAINT placements_source_check;
ALTER TABLE placements ADD CONSTRAINT placements_source_check
    CHECK (source IN ('receipt','putaway','move','stock_entry'));

DELETE FROM warehouse_problem_lines
WHERE problem_id IN (SELECT id FROM warehouse_problems WHERE reason = 'not_found');
UPDATE cz_marks SET problem_id = NULL
WHERE problem_id IN (SELECT id FROM warehouse_problems WHERE reason = 'not_found');
DELETE FROM problem_photos
WHERE problem_id IN (SELECT id FROM warehouse_problems WHERE reason = 'not_found');
DELETE FROM warehouse_problems WHERE reason = 'not_found';
ALTER TABLE warehouse_problems DROP CONSTRAINT warehouse_problems_reason_check;
ALTER TABLE warehouse_problems ADD CONSTRAINT warehouse_problems_reason_check
    CHECK (reason IN ('breakage','spoilage','expired','foreign_mark','retired','other'));

UPDATE internal_warehouses SET system_role = NULL WHERE system_role = 'not_found';
DELETE FROM internal_warehouses w
WHERE w.code = 'NOT_FOUND'
  AND NOT EXISTS (SELECT 1 FROM stock s WHERE s.internal_warehouse_id = w.id)
  AND NOT EXISTS (SELECT 1 FROM load_units lu WHERE lu.internal_warehouse_id = w.id)
  AND NOT EXISTS (SELECT 1 FROM cz_marks m WHERE m.internal_warehouse_id = w.id)
  AND NOT EXISTS (SELECT 1 FROM warehouse_problems p
                  WHERE p.from_internal_warehouse_id = w.id OR p.to_internal_warehouse_id = w.id);
ALTER TABLE internal_warehouses DROP CONSTRAINT internal_warehouses_system_role_check;
ALTER TABLE internal_warehouses ADD CONSTRAINT internal_warehouses_system_role_check
    CHECK (system_role IN ('supplier_return'));
