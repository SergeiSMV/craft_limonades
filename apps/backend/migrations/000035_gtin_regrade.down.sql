-- ADHOC-53: откат пересорта. Проблемы «Пересорт» удаляются вместе со строками и ссылками марок:
-- прежняя схема их не выражает. Сам перевод марок и остатка на новый товар откат не отменяет —
-- это движение уже случилось на складе.
UPDATE cz_marks SET problem_id = NULL
WHERE problem_id IN (SELECT id FROM warehouse_problems WHERE reason = 'regrade');
DELETE FROM warehouse_problem_lines
WHERE problem_id IN (SELECT id FROM warehouse_problems WHERE reason = 'regrade');
DELETE FROM problem_photos
WHERE problem_id IN (SELECT id FROM warehouse_problems WHERE reason = 'regrade');
DELETE FROM warehouse_problems WHERE reason = 'regrade';

UPDATE positions SET rights = array_remove(rights, 'tsd.stock.regrade');
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
    'tsd.stock.view', 'tsd.stock.cz_marked', 'tsd.stock_entry',
    'tsd.problems.view', 'tsd.problems.mark'
]::text[]);

ALTER TABLE warehouse_problems DROP CONSTRAINT warehouse_problems_shape_check;
ALTER TABLE warehouse_problems ADD CONSTRAINT warehouse_problems_check1 CHECK (
    (load_unit_id IS NOT NULL
        AND good_id IS NULL AND batch_id IS NULL AND qty IS NULL AND from_load_unit_id IS NULL)
 OR (load_unit_id IS NULL
        AND good_id IS NOT NULL AND batch_id IS NOT NULL AND qty > 0)
);

ALTER TABLE warehouse_problems
    DROP COLUMN barcode,
    DROP COLUMN from_good_id,
    ALTER COLUMN cell_id SET NOT NULL,
    ALTER COLUMN from_internal_warehouse_id SET NOT NULL,
    ALTER COLUMN to_internal_warehouse_id SET NOT NULL;

ALTER TABLE warehouse_problems DROP CONSTRAINT warehouse_problems_write_off_check;
ALTER TABLE warehouse_problems ADD CONSTRAINT warehouse_problems_write_off_check CHECK (
    COALESCE(decision = 'write_off', false) = (doc_number IS NOT NULL AND doc_date IS NOT NULL));
ALTER TABLE warehouse_problems DROP CONSTRAINT warehouse_problems_decision_check;
ALTER TABLE warehouse_problems ADD CONSTRAINT warehouse_problems_decision_check
    CHECK (decision IN ('write_off','place','supplier_return'));

ALTER TABLE warehouse_problems DROP CONSTRAINT warehouse_problems_reason_check;
ALTER TABLE warehouse_problems ADD CONSTRAINT warehouse_problems_reason_check
    CHECK (reason IN ('breakage','spoilage','expired','foreign_mark','retired','not_found','other'));
