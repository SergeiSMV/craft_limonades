-- ADHOC-57: стеллажи и настройки этикеток ячеек - перенос проекта rack_labels в портал.
--
-- Что: стеллаж (код вида «B-01») с признаком «карточка на стойку»; у ячейки - ссылка на стеллаж
-- и два признака этикетки: «малая балка» и «штрих-код на этикетке». Признак «нижняя ячейка»
-- отдельной колонкой не заводится: это уже существующий is_floor (стрелка вниз на этикетке).
-- Зачем: этикетки на балки и карточки на стойки печатаются из портала, а их настройки правятся
-- галочками на странице «Ячейки» и загружаются/выгружаются файлом в формате rack_labels.
-- Как: стеллаж - отдельная таблица, потому что «карточка на стойку» - свойство стеллажа, а не
-- ячейки (одна галочка на весь стеллаж); номер стеллажа из адреса не выводится (B-1-1-12 стоит
-- на B-05), поэтому ссылка хранится явно. Ячейка без стеллажа допустима: она печатается на балку,
-- но не попадает ни на одну карточку.

CREATE TABLE racks (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    warehouse_id uuid        NOT NULL REFERENCES warehouses(id),
    code         text        NOT NULL,                      -- «B-01», как rack_id в файле
    side_card    boolean     NOT NULL DEFAULT false,        -- печатать карточку на стойку
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (warehouse_id, code)
);

CREATE TRIGGER racks_set_updated_at
    BEFORE UPDATE ON racks
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Стеллаж обязан быть того же склада, что и ячейка - это проверяет сервис при импорте и правке:
-- составной внешний ключ потребовал бы второго уникального индекса ради одной проверки.
ALTER TABLE cells
    ADD COLUMN rack_id       uuid    REFERENCES racks(id) ON DELETE SET NULL,
    ADD COLUMN label_small   boolean NOT NULL DEFAULT false,  -- малая балка: этикетка 190×46 мм
    ADD COLUMN label_barcode boolean NOT NULL DEFAULT false;  -- штрих-код на этикетке балки

CREATE INDEX cells_rack_id_idx ON cells (rack_id);

-- Право «Ячейки: изменять настройки» - галочки этикеток и стеллажей. «Администратор» (системная
-- должность) получает его сам; остальным должностям - по решению в портале.
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
    'portal.settings.warehouses', 'portal.settings.problem_reasons', 'portal.settings.users',
    'tsd.receipt', 'tsd.movement',
    'tsd.tasks.putaway', 'tsd.tasks.stocktake_count', 'tsd.tasks.stocktake_manage',
    'tsd.stock.view', 'tsd.stock.cz_marked', 'tsd.stock.regrade', 'tsd.stock_entry',
    'tsd.problems.view', 'tsd.problems.mark'
]::text[]);
