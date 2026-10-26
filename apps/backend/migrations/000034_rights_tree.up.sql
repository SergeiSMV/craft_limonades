-- ADHOC-50: права должности — дерево «раздел → действия» вместо девяти кодов ADHOC-49.
--
-- Решение 2026-10-26: права должны совпадать с экранами. Код права — «приложение.раздел.
-- действие» (portal.receipt.post — «Приход: проводить»); группы дерева (раздел, приложение)
-- в базе не хранятся — их рисует портал, галочка раздела ставит все его действия.

ALTER TABLE positions DROP CONSTRAINT positions_rights_check;

-- Прежний код → новые действия. «Работа на ТСД» — всё на ТСД, кроме того, что раньше было
-- отдельными правами (заводить пересчёт, признак ЧЗ); «вход в портал» отдельного действия не
-- имеет — в портал пускает любой его раздел.
WITH map(old, new) AS (VALUES
    ('tsd', 'tsd.receipt'), ('tsd', 'tsd.movement'), ('tsd', 'tsd.tasks.putaway'),
    ('tsd', 'tsd.tasks.stocktake_count'), ('tsd', 'tsd.stock.view'), ('tsd', 'tsd.stock_entry'),
    ('tsd', 'tsd.problems.view'), ('tsd', 'tsd.problems.mark'),
    ('catalog', 'portal.nomenclature.import'), ('catalog', 'portal.cells.import'),
    ('catalog', 'portal.cells.labels'),
    ('documents', 'portal.receipt.view'), ('documents', 'portal.receipt.download'),
    ('documents', 'portal.receipt.post'),
    ('documents', 'portal.movement.view'), ('documents', 'portal.movement.download'),
    ('documents', 'portal.movement.post'),
    ('documents', 'portal.stocktake_doc.view'), ('documents', 'portal.stocktake_doc.download'),
    ('documents', 'portal.stocktake_doc.post'),
    ('documents', 'portal.stock_entry_doc.view'), ('documents', 'portal.stock_entry_doc.download'),
    ('documents', 'portal.stock_entry_doc.post'),
    ('problems', 'portal.problems.view'), ('problems', 'portal.problems.resolve'),
    ('stocktake', 'portal.stocktake.view'), ('stocktake', 'portal.stocktake.manage'),
    ('stocktake', 'tsd.tasks.stocktake_manage'),
    ('warehouses', 'portal.settings.warehouses'),
    ('cz', 'tsd.stock.cz_marked'),
    ('users', 'portal.settings.users')
)
UPDATE positions p SET rights = COALESCE((
    SELECT array_agg(DISTINCT m.new ORDER BY m.new) FROM map m WHERE m.old = ANY (p.rights)
), '{}');

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

COMMENT ON COLUMN positions.rights IS
    'ADHOC-50: действия должности, код «приложение.раздел.действие» (portal.receipt.post). '
    'Системная должность — все действия, список не читается.';
