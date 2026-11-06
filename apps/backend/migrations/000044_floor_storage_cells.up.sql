-- ADHOC-61: напольное хранение и отдельная ячейка приёмки.
--
-- Что: у ячейки — признак is_floor_storage «напольное хранение» (пол у стеллажа, адрес вида
-- `D-Н-П`); на каждом складе — новая ячейка `ПРИЁМКА`, признак ячейки приёмки (is_default)
-- переезжает на неё; `С-Н-П` и все ячейки с адресом на `-Н-П` становятся напольными.
-- Зачем: реестр 1С на сборку адресует пол у стеллажа как `<стеллаж>-Н-П`, и сборка из него
-- разрешена. Товар, который числится в `С-Н-П`, физически лежит на полу у стеллажа C — он
-- остаётся на месте, ячейкой приёмки становится пустая `ПРИЁМКА`.
-- Как: is_floor_storage — не is_floor: тот означает нижний ярус стеллажа (стрелка вниз на
-- этикетке балки). Признак приёмки снимается до того, как ставится: частичный уникальный
-- индекс cells_default_idx допускает одну ячейку приёмки на склад.

ALTER TABLE cells
    ADD COLUMN is_floor_storage boolean NOT NULL DEFAULT false;  -- напольное хранение

COMMENT ON COLUMN cells.is_floor_storage IS
    'ADHOC-61: напольное хранение у стеллажа (адрес на «-Н-П»): ведётся вручную в портале.';

UPDATE cells SET is_default = false WHERE is_default;

INSERT INTO cells (warehouse_id, address, is_default)
SELECT id, 'ПРИЁМКА', true FROM warehouses
ON CONFLICT (warehouse_id, address) DO UPDATE SET is_default = true, is_active = true;

UPDATE cells SET is_floor_storage = true, rack_id = NULL, side_card = false
WHERE address LIKE '%-Н-П' AND NOT is_default;

COMMENT ON COLUMN cells.is_default IS
    'P4-03: ячейка приёмки по умолчанию (с ADHOC-61 — «ПРИЁМКА»). Одна на склад — частичный уникальный индекс.';
