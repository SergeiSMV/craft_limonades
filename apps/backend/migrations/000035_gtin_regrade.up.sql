-- ADHOC-53: пересорт марок ЧЗ при перепривязке ШК (GTIN) к другому товару.
--
-- Решение 2026-10-28: ШК маркируемого товара, у которого на складе есть марки, не отвязывается,
-- а перепривязывается к правильному товару. Марки этого GTIN, их остаток и состав коробов в той
-- же транзакции переходят на новый товар, а в «Проблемах склада» появляется проблема «Пересорт»:
-- офис проводит её номером и датой документа пересортицы 1С.
--
-- Пересорт - не метка склада: товар не переезжает на другой внутренний склад и лежит, где
-- лежал, иногда в нескольких ячейках и коробах сразу. Поэтому у такой проблемы нет ячейки и пары
-- складов «откуда → куда», а что она взяла, записано строками warehouse_problem_lines сразу при
-- заведении. Товар проблемы (good_id) - новый, from_good_id - прежний, barcode - перепривязанный ШК.

ALTER TABLE warehouse_problems DROP CONSTRAINT warehouse_problems_reason_check;
ALTER TABLE warehouse_problems ADD CONSTRAINT warehouse_problems_reason_check
    CHECK (reason IN ('breakage','spoilage','expired','foreign_mark','retired','not_found',
                      'regrade','other'));

-- Решение «Провести пересорт» - документ пересортицы 1С, как у списания.
ALTER TABLE warehouse_problems DROP CONSTRAINT warehouse_problems_decision_check;
ALTER TABLE warehouse_problems ADD CONSTRAINT warehouse_problems_decision_check
    CHECK (decision IN ('write_off','place','supplier_return','regrade'));
ALTER TABLE warehouse_problems DROP CONSTRAINT warehouse_problems_write_off_check;
ALTER TABLE warehouse_problems ADD CONSTRAINT warehouse_problems_write_off_check CHECK (
    COALESCE(decision IN ('write_off','regrade'), false) = (doc_number IS NOT NULL AND doc_date IS NOT NULL));

ALTER TABLE warehouse_problems
    ALTER COLUMN cell_id DROP NOT NULL,
    ALTER COLUMN from_internal_warehouse_id DROP NOT NULL,
    ALTER COLUMN to_internal_warehouse_id DROP NOT NULL,
    ADD COLUMN from_good_id uuid REFERENCES goods(id),
    ADD COLUMN barcode      text;

-- Форма проблемы: прежняя (короб целиком ЛИБО товар партии, с ячейкой и парой складов) или
-- пересорт (товар - новый, прежний и ШК; ячейки, складов, партии и короба нет; количество -
-- сколько марок перешло). Прежнее безымянное ограничение формы - warehouse_problems_check1.
ALTER TABLE warehouse_problems DROP CONSTRAINT warehouse_problems_check1;
ALTER TABLE warehouse_problems ADD CONSTRAINT warehouse_problems_shape_check CHECK (
    (reason <> 'regrade'
        AND cell_id IS NOT NULL AND from_internal_warehouse_id IS NOT NULL
        AND to_internal_warehouse_id IS NOT NULL AND from_good_id IS NULL AND barcode IS NULL
        AND ((load_unit_id IS NOT NULL
                AND good_id IS NULL AND batch_id IS NULL AND qty IS NULL AND from_load_unit_id IS NULL)
          OR (load_unit_id IS NULL
                AND good_id IS NOT NULL AND batch_id IS NOT NULL AND qty > 0)))
 OR (reason = 'regrade'
        AND cell_id IS NULL AND from_internal_warehouse_id IS NULL AND to_internal_warehouse_id IS NULL
        AND load_unit_id IS NULL AND from_load_unit_id IS NULL AND batch_id IS NULL
        AND good_id IS NOT NULL AND from_good_id IS NOT NULL AND good_id <> from_good_id
        AND barcode IS NOT NULL AND qty > 0)
);

COMMENT ON COLUMN warehouse_problems.from_good_id IS
    'ADHOC-53: пересорт - товар, за которым марки числились до перепривязки ШК.';
COMMENT ON COLUMN warehouse_problems.barcode IS
    'ADHOC-53: пересорт - ШК (GTIN), перепривязанный к товару проблемы.';

-- Право «Остатки: перепривязать ШК маркируемого товара». Решение 2026-10-28: пока только у
-- «Администратора» (системная должность получает все права), должностям его выдают в портале.
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
