-- ADHOC-55: откат справочника причин и вариантов. Проблемы с причинами, заведёнными в портале,
-- прежняя схема не выражает - они получают «Прочее»; решение - прежним действием (`decision`).
UPDATE positions SET rights = array_remove(rights, 'portal.settings.problem_reasons');
ALTER TABLE positions DROP CONSTRAINT positions_rights_check;
ALTER TABLE positions ADD CONSTRAINT positions_rights_check CHECK (rights <@ ARRAY[
    'portal.nomenclature.import',
    'portal.receipt.view', 'portal.receipt.download', 'portal.receipt.post',
    'portal.stocktake.view', 'portal.stocktake.manage',
    'portal.stocktake_doc.view', 'portal.stocktake_doc.download', 'portal.stocktake_doc.post',
    'portal.stock_entry_doc.view', 'portal.stock_entry_doc.download', 'portal.stock_entry_doc.post',
    'portal.cells.import', 'portal.cells.labels',
    'portal.movement.view', 'portal.movement.download', 'portal.movement.post',
    'portal.problems.view', 'portal.problems.resolve',
    'portal.settings.warehouses', 'portal.settings.users',
    'tsd.receipt', 'tsd.movement',
    'tsd.tasks.putaway', 'tsd.tasks.stocktake_count', 'tsd.tasks.stocktake_manage',
    'tsd.stock.view', 'tsd.stock.cz_marked', 'tsd.stock.regrade', 'tsd.stock_entry',
    'tsd.problems.view', 'tsd.problems.mark'
]::text[]);

ALTER TABLE warehouse_problems DROP CONSTRAINT warehouse_problems_resolution_check;
ALTER TABLE warehouse_problems DROP COLUMN resolution_id;
ALTER TABLE warehouse_problems DROP CONSTRAINT warehouse_problems_reason_fkey;
UPDATE warehouse_problems SET reason = 'other'
WHERE reason NOT IN ('breakage','spoilage','expired','foreign_mark','retired','not_found',
                     'regrade','other');
ALTER TABLE warehouse_problems ADD CONSTRAINT warehouse_problems_reason_check
    CHECK (reason IN ('breakage','spoilage','expired','foreign_mark','retired','not_found',
                      'regrade','other'));

DROP TABLE problem_reason_resolutions;
DROP FUNCTION problem_reason_resolutions_check();
DROP TABLE problem_reasons;
DROP TABLE problem_resolutions;
