-- P9-07 откат: журнал событий заказа сборки и источник размещения «сборка».
--
-- Строки журнала размещений от «Завершить сборку» удаляются: старое ограничение их не пропустит.
-- Место коробов отгрузки (`load_units.cell_id`) остаётся - это текущее состояние, не история.
DROP TABLE picking_order_events;

DELETE FROM placements WHERE source = 'picking';
ALTER TABLE placements DROP CONSTRAINT placements_source_check;
ALTER TABLE placements ADD CONSTRAINT placements_source_check
    CHECK (source IN ('receipt','putaway','move','stock_entry','stocktake'));

-- Убранные пустые короба удаляются вместе с возвращёнными пиками на них: иначе старая
-- уникальность номера короба в заказе не встанет.
DELETE FROM picking_picks WHERE box_id IN (SELECT load_unit_id FROM picking_boxes WHERE dropped_at IS NOT NULL);
DELETE FROM picking_boxes WHERE dropped_at IS NOT NULL;
DROP INDEX picking_boxes_order_seq_uq;
ALTER TABLE picking_boxes
    DROP COLUMN dropped_at,
    ADD CONSTRAINT picking_boxes_order_id_seq_key UNIQUE (order_id, seq);
