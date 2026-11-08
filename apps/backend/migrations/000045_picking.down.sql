-- P9-02 откат: таблицы сборки, область версий «picking», признаки склада и ячейки.
--
-- Ячейка `ОТГРУЗКА` остаётся строкой без признака: к моменту отката в ней уже могли числиться
-- короба, а журнал размещений ссылается на неё. Короба со статусом shipped возвращаются в
-- closed без места — иначе старое ограничение статусов их не пропустит.

DROP TABLE picking_pick_marks;
DROP TABLE picking_picks;
DROP TABLE picking_boxes;
DROP TABLE picking_order_changes;
DROP TABLE picking_order_lines;
DROP TABLE picking_orders;
DROP TABLE picking_loads;

DELETE FROM data_versions WHERE domain = 'picking';

UPDATE load_units SET status = 'closed' WHERE status = 'shipped';
ALTER TABLE load_units DROP CONSTRAINT load_units_status_check;
ALTER TABLE load_units ADD CONSTRAINT load_units_status_check
    CHECK (status IN ('open','closed','placed'));

DROP INDEX cells_shipping_idx;
ALTER TABLE cells DROP CONSTRAINT cells_shipping_not_default;
ALTER TABLE cells DROP COLUMN is_shipping;

ALTER TABLE internal_warehouses DROP COLUMN allow_picking;
