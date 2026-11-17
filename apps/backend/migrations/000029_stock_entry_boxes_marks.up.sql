-- ADHOC-46: короба с QR, короба ЧЗ и марки во «Вводе остатков».
--
-- Решения (2026-10-25). Проход склада заводит короба и марки так же, как приёмка: свой короб с
-- QR, короб ЧЗ одним сканом SSCC, марки только со связью. До финала всё это живёт в сессии:
-- ГЕ, состав, марки и упаковки появляются на складе в транзакции финала вместе с остатком -
-- иначе брошенная сессия оставила бы на складе короб без остатка.

-- --- Короба сессии --------------------------------------------------------------------------
--
-- Короб, заведённый в ячейке прохода. Идентификатор выдал ТСД (он же в QR ярлыка), ГЕ с ним
-- создаётся на финале - поэтому внешнего ключа на load_units нет.
CREATE TABLE stock_entry_load_units (
    session_id   uuid NOT NULL REFERENCES stock_entry_sessions(id) ON DELETE CASCADE,
    load_unit_id uuid NOT NULL,
    cell_id      uuid NOT NULL REFERENCES cells(id),
    kind         text NOT NULL CHECK (kind IN ('box','pallet')),
    -- Код короба ЧЗ (`00`+SSCC), которым является эта ГЕ; NULL - свой короб с QR.
    cz_code      text CHECK (cz_code IS NULL OR cz_code ~ '^00[0-9]{18}$'),
    PRIMARY KEY (session_id, load_unit_id)
);

-- Короб ЧЗ в сессии один раз: второй скан того же SSCC - тот же короб.
CREATE UNIQUE INDEX stock_entry_load_units_cz_code_key
    ON stock_entry_load_units (session_id, cz_code) WHERE cz_code IS NOT NULL;

COMMENT ON TABLE stock_entry_load_units IS
    'ADHOC-46: короба прохода ввода остатков до финала (ГЕ заводится финалом).';

-- --- Групповые упаковки ЧЗ сессии -----------------------------------------------------------
--
-- Упаковка из состава короба ЧЗ или скана. Родитель - короб или упаковка той же сессии
-- (проверяет сервис); пусто - упаковка сама по себе.
CREATE TABLE stock_entry_cz_groups (
    session_id  uuid NOT NULL REFERENCES stock_entry_sessions(id) ON DELETE CASCADE,
    cell_id     uuid NOT NULL REFERENCES cells(id),
    code        text NOT NULL CHECK (code ~ '^01[0-9]{14}21[^\x1d]+$'),
    parent_code text,
    PRIMARY KEY (session_id, code)
);

COMMENT ON TABLE stock_entry_cz_groups IS
    'ADHOC-46: групповые упаковки ЧЗ прохода ввода остатков до финала.';

-- --- Строка сессии в коробе ----------------------------------------------------------------
--
-- Товар в коробе прохода - своя строка: грань строки теперь (ячейка · товар · партия · короб),
-- NULL - россыпь. NULLS NOT DISTINCT: россыпь той же грани - одна строка, как и раньше.
ALTER TABLE stock_entry_lines ADD COLUMN load_unit_id uuid;
ALTER TABLE stock_entry_lines ADD CONSTRAINT stock_entry_lines_load_unit_fkey
    FOREIGN KEY (session_id, load_unit_id)
    REFERENCES stock_entry_load_units (session_id, load_unit_id) ON DELETE CASCADE;

-- Имя прежнего ограничения Postgres обрезал до 63 символов - ищем его по таблице, а не по имени.
DO $$
DECLARE c text;
BEGIN
    SELECT conname INTO c FROM pg_constraint
    WHERE conrelid = 'stock_entry_lines'::regclass AND contype = 'u';
    EXECUTE format('ALTER TABLE stock_entry_lines DROP CONSTRAINT %I', c);
END $$;

ALTER TABLE stock_entry_lines ADD CONSTRAINT stock_entry_lines_facet_key
    UNIQUE NULLS NOT DISTINCT (session_id, cell_id, good_id, production_date, load_unit_id);

COMMENT ON COLUMN stock_entry_lines.load_unit_id IS
    'ADHOC-46: короб прохода, в котором лежит товар строки; NULL - россыпь.';

-- --- Марки сессии --------------------------------------------------------------------------
--
-- Марка ЧЗ строки прохода. Товар и партия - у строки; место - короб строки или россыпь её
-- ячейки. Марка в сессии одна: её второй скан - та же марка.
CREATE TABLE stock_entry_marks (
    session_id     uuid NOT NULL REFERENCES stock_entry_sessions(id) ON DELETE CASCADE,
    line_id        uuid NOT NULL REFERENCES stock_entry_lines(id) ON DELETE CASCADE,
    cis            text NOT NULL CHECK (cis ~ '^01[0-9]{14}21[^\x1d]+$'),
    -- Упаковка ЧЗ, в которой марка пришла (`parent` ответа ЧЗ); NULL - сама по себе.
    aggregate_code text,
    -- Расхождение со скана (CZ-05): чужой владелец, не в обороте; NULL - нет.
    discrepancy    text CHECK (discrepancy IN ('foreign_mark','retired')),
    PRIMARY KEY (session_id, cis)
);

CREATE INDEX stock_entry_marks_line_idx ON stock_entry_marks (line_id);

COMMENT ON TABLE stock_entry_marks IS
    'ADHOC-46: марки ЧЗ строк прохода ввода остатков до финала.';

-- --- Журнал размещений узнаёт ввод остатков ------------------------------------------------
--
-- Короб, заведённый проходом, получает первую строку журнала: история короба (ADHOC-32)
-- показывает, откуда он взялся.
ALTER TABLE placements DROP CONSTRAINT placements_source_check;
ALTER TABLE placements ADD CONSTRAINT placements_source_check
    CHECK (source IN ('receipt','putaway','move','stock_entry'));
ALTER TABLE placements ADD COLUMN stock_entry_session_id uuid REFERENCES stock_entry_sessions(id);
