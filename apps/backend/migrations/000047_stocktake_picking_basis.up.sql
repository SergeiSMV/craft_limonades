-- P9-04: пересчёт позиции по нехватке при сборке.
--
-- Кладовщик отметил по строке заказа «не хватает» — WMS сама заводит пересчёт этого товара в
-- ячейках, где его числит, плюс в ячейке реестра (docs/picking.md, «Нехватка»). Основание
-- пересчёта — заказ сборки: «Нехватка при сборке: накладная №, заказ №». По нему же видно, что
-- по товару такой пересчёт уже открыт, и второй не заводится.
ALTER TABLE stocktakes
    ADD COLUMN picking_order_id uuid REFERENCES picking_orders(id);

CREATE INDEX stocktakes_picking_order_idx ON stocktakes (picking_order_id)
    WHERE picking_order_id IS NOT NULL;

COMMENT ON COLUMN stocktakes.picking_order_id IS
    'P9-04: пересчёт заведён нехваткой при сборке этого заказа; NULL — заведён старшим смены.';
