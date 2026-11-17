-- P10-03: подсчёт ячейки пересчёта - «не найдено», перенос найденного короба, ссылки на проблемы.
--
-- Решения 2026-10-26. Остаток приводится к факту сразу по ячейке, когда приходит её подсчёт.
-- Короб или марка, ожидавшиеся в ячейке и не найденные, уходят с «Основного» на системный склад
-- «Не найдено» проблемой склада с причиной «не найдено»: судьбу решает офис - списать по
-- документу 1С или «нашлось» (вернуть в «Основной»). Учётный короб, найденный не в своей
-- ячейке, пересчёт переносит туда, где его нашли, - строкой журнала размещений.

-- --- Склад «Не найдено» ----------------------------------------------------------------------
--
-- Системный, как «Возврат поставщику»: туда переводит только программа, вручную его не выбрать,
-- не скрыть и не удалить. Код NOT_FOUND мог завести admin - тогда системным становится он.
ALTER TABLE internal_warehouses DROP CONSTRAINT internal_warehouses_system_role_check;
ALTER TABLE internal_warehouses ADD CONSTRAINT internal_warehouses_system_role_check
    CHECK (system_role IN ('supplier_return','not_found'));

INSERT INTO internal_warehouses (code, name, system_role)
VALUES ('NOT_FOUND', 'Не найдено', 'not_found')
ON CONFLICT (code) DO UPDATE SET system_role = 'not_found', is_active = true;

-- --- Причина «не найдено» --------------------------------------------------------------------
ALTER TABLE warehouse_problems DROP CONSTRAINT warehouse_problems_reason_check;
ALTER TABLE warehouse_problems ADD CONSTRAINT warehouse_problems_reason_check
    CHECK (reason IN ('breakage','spoilage','expired','foreign_mark','retired','not_found','other'));

-- --- Перенос короба пересчётом ---------------------------------------------------------------
ALTER TABLE placements DROP CONSTRAINT placements_source_check;
ALTER TABLE placements ADD CONSTRAINT placements_source_check
    CHECK (source IN ('receipt','putaway','move','stock_entry','stocktake'));
ALTER TABLE placements ADD COLUMN stocktake_cell_id uuid REFERENCES stocktake_cells(id);

COMMENT ON COLUMN placements.stocktake_cell_id IS
    'P10-03: ячейка пересчёта, в которой нашли учётный короб из другой ячейки.';

-- --- Ссылки на проблемы «не найдено» ---------------------------------------------------------
--
-- Строка короба и марка, по которым заведена проблема, - для отчёта «Инвентаризация» (P10-05):
-- по ней видно, что недостача ушла офису на решение, а не списана молча.
ALTER TABLE stocktake_lines ADD COLUMN problem_id uuid REFERENCES warehouse_problems(id);
ALTER TABLE stocktake_marks ADD COLUMN problem_id uuid REFERENCES warehouse_problems(id);
