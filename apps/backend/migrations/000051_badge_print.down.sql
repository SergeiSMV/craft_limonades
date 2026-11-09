-- ADHOC-65: откат печати бейджей — права и сохранённые номера.
UPDATE positions SET rights = array_remove(array_remove(array_remove(rights,
    'tsd.badges.own'), 'tsd.badges.staff'), 'tsd.badges.all');
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
    'tsd.tasks.picking_return',
    'tsd.stock.view', 'tsd.stock.cz_marked', 'tsd.stock.regrade', 'tsd.stock_entry',
    'tsd.problems.view', 'tsd.problems.mark',
    'tsd.picking', 'tsd.picking.reprint'
]::text[]);

ALTER TABLE users DROP COLUMN badge_secret_enc;
