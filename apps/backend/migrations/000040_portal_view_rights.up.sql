-- ADHOC-56: права «Номенклатура склада: смотреть» и «Остатки склада: смотреть».
--
-- Решение 2026-10-30: в портале появляются страницы «Номенклатура склада» (справочник с
-- карточками товара, как на ТСД) и «Остатки склада» (товары с ненулевым остатком) — каждая под
-- своим правом. «Администратор» (системная должность) получает их сам. Кто загружал номенклатуру,
-- тот видел и её страницу — ему «смотреть» ставится сразу, чтобы раздел не пропал из меню.

ALTER TABLE positions DROP CONSTRAINT positions_rights_check;
ALTER TABLE positions ADD CONSTRAINT positions_rights_check CHECK (rights <@ ARRAY[
    'portal.nomenclature.view', 'portal.nomenclature.import',
    'portal.stock.view',
    'portal.receipt.view', 'portal.receipt.download', 'portal.receipt.post',
    'portal.stocktake.view', 'portal.stocktake.manage',
    'portal.stocktake_doc.view', 'portal.stocktake_doc.download', 'portal.stocktake_doc.post',
    'portal.stock_entry_doc.view', 'portal.stock_entry_doc.download', 'portal.stock_entry_doc.post',
    'portal.cells.import', 'portal.cells.labels',
    'portal.movement.view', 'portal.movement.download', 'portal.movement.post',
    'portal.problems.view', 'portal.problems.resolve',
    'portal.settings.warehouses', 'portal.settings.problem_reasons', 'portal.settings.users',
    'tsd.receipt', 'tsd.movement',
    'tsd.tasks.putaway', 'tsd.tasks.stocktake_count', 'tsd.tasks.stocktake_manage',
    'tsd.stock.view', 'tsd.stock.cz_marked', 'tsd.stock.regrade', 'tsd.stock_entry',
    'tsd.problems.view', 'tsd.problems.mark'
]::text[]);

-- Системной должности список не нужен: она получает все права сама.
UPDATE positions SET rights = array_append(rights, 'portal.nomenclature.view')
WHERE NOT is_system AND 'portal.nomenclature.import' = ANY (rights)
  AND NOT 'portal.nomenclature.view' = ANY (rights);
