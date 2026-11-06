-- ADHOC-61 откат: ячейка приёмки снова `С-Н-П`, признак напольного хранения снят.
--
-- Ячейка `ПРИЁМКА` остаётся строкой без признака: к моменту отката в неё уже могли
-- приходовать, а строки приёмки и остатка ссылаются на неё.

UPDATE cells SET is_default = false WHERE is_default;

INSERT INTO cells (warehouse_id, address, is_default)
SELECT id, 'С-Н-П', true FROM warehouses
ON CONFLICT (warehouse_id, address) DO UPDATE SET is_default = true, is_active = true;

ALTER TABLE cells DROP COLUMN is_floor_storage;

COMMENT ON COLUMN cells.is_default IS
    'P4-03: ячейка приёмки по умолчанию (С-Н-П). Одна на склад — частичный уникальный индекс.';
