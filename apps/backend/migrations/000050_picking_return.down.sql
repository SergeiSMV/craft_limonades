-- P9-07-1 откат: задание «вернуть на места», возвраты из коробов отгрузки, право.
--
-- Возвраты и задания удаляются: старые ограничения их не пропустят. Остаток и пики, которые
-- возвраты изменили, остаются — это текущее состояние склада, не история.
DROP TABLE picking_return_marks;
DROP TABLE picking_returns;

DELETE FROM warehouse_tasks WHERE kind = 'picking_return';
DROP INDEX warehouse_tasks_open_picking_uq;
ALTER TABLE warehouse_tasks
    DROP CONSTRAINT warehouse_tasks_picking_kind,
    DROP COLUMN picking_order_id,
    DROP CONSTRAINT warehouse_tasks_kind_check,
    ADD CONSTRAINT warehouse_tasks_kind_check CHECK (kind IN ('putaway','supplier_return','stocktake'));

DELETE FROM picking_order_events WHERE kind = 'returned';
ALTER TABLE picking_order_events DROP CONSTRAINT picking_order_events_kind_check;
ALTER TABLE picking_order_events ADD CONSTRAINT picking_order_events_kind_check CHECK (kind IN (
    'taken', 'taken_over', 'released', 'released_by_lead', 'completed', 'reopened', 'shipped'));
ALTER TABLE picking_order_events DROP CONSTRAINT picking_order_events_totals;
ALTER TABLE picking_order_events ADD CONSTRAINT picking_order_events_totals CHECK (
    (kind IN ('completed', 'shipped')) = (boxes IS NOT NULL AND qty IS NOT NULL));

UPDATE positions SET rights = array_remove(rights, 'tsd.tasks.picking_return');
ALTER TABLE positions DROP CONSTRAINT positions_rights_check;
ALTER TABLE positions ADD CONSTRAINT positions_rights_check CHECK (rights <@ ARRAY[
    'portal.nomenclature.view', 'portal.nomenclature.import',
    'portal.stock.view',
    'portal.receipt.view', 'portal.receipt.download', 'portal.receipt.post',
    'portal.stocktake.view', 'portal.stocktake.manage',
    'portal.stocktake_doc.view', 'portal.stocktake_doc.download', 'portal.stocktake_doc.post',
    'portal.stock_entry_doc.view', 'portal.stock_entry_doc.download', 'portal.stock_entry_doc.post',
    'portal.cells.import', 'portal.cells.labels', 'portal.cells.edit',
    'portal.movement.view', 'portal.movement.download', 'portal.movement.post',
    'portal.problems.view', 'portal.problems.resolve',
    'portal.picking.view', 'portal.picking.load', 'portal.picking.download', 'portal.picking.release',
    'portal.settings.warehouses', 'portal.settings.problem_reasons', 'portal.settings.users',
    'tsd.receipt', 'tsd.movement',
    'tsd.tasks.putaway', 'tsd.tasks.stocktake_count', 'tsd.tasks.stocktake_manage',
    'tsd.stock.view', 'tsd.stock.cz_marked', 'tsd.stock.regrade', 'tsd.stock_entry',
    'tsd.problems.view', 'tsd.problems.mark',
    'tsd.picking', 'tsd.picking.reprint'
]::text[]);
