-- Откат ADHOC-31: отгрузка возврата поставщику. Отгруженные позиции снова числятся
-- неотгруженными; остаток, который сеансы успели снять, остаётся как есть - откат схемы
-- не откатывает складские факты.
ALTER TABLE task_events DROP COLUMN IF EXISTS shipment_id;
ALTER TABLE warehouse_problems
    DROP CONSTRAINT IF EXISTS warehouse_problems_shipment_check,
    DROP COLUMN IF EXISTS shipment_id;
DROP TABLE IF EXISTS supplier_return_shipment_lines;
DROP TABLE IF EXISTS supplier_return_shipments;
