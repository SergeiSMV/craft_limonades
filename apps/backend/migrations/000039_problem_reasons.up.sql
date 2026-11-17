-- ADHOC-55: справочник причин проблем склада и вариантов решения - ведёт офис в портале.
--
-- Решение 2026-10-29. До сих пор причины и допустимые при них решения были зашиты в код и в
-- CHECK: любая новая причина - миграция. Теперь:
--   вариант решения - название и одно из четырёх действий кода (списать, разместить, вернуть
--     поставщику, провести пересорт): действие делает с товаром программа, название видит офис;
--   причина - название, флаг «комментарий обязателен» и список допустимых вариантов.
-- Удаления нет: причина и вариант становятся неактивными - в выбор не попадают, а старые
-- проблемы и документы показываются как были. Системные причины (не наша марка, марка выбыла,
-- не найдено пересчётом, пересорт) заводит программа: их можно переименовать и поменять им
-- варианты, но не выключить. Жёсткое правило одно: вариант «пересорт» - только у причины
-- «Пересорт» и наоборот, у неё - только такие варианты: пересорт уже проведён перепривязкой,
-- товара в ячейке у такой проблемы нет, другое действие с ним невозможно.

-- --- Варианты решения -------------------------------------------------------------------------
CREATE TABLE problem_resolutions (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Порядок показа - порядок заведения.
    ord        bigint      GENERATED ALWAYS AS IDENTITY UNIQUE,
    name       text        NOT NULL CHECK (btrim(name) <> '' AND char_length(name) <= 100),
    -- Действие не меняется после заведения: им уже проведены решения старых проблем.
    action     text        NOT NULL CHECK (action IN ('write_off','place','supplier_return','regrade')),
    is_active  boolean     NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX problem_resolutions_name_uq ON problem_resolutions (lower(name));

COMMENT ON TABLE problem_resolutions IS
    'ADHOC-55: вариант решения проблемы склада - название для офиса и действие кода. '
    'Неактивный не предлагается, у решённых проблем показывается как был.';

-- Прежние четыре решения - вариантами с теми же названиями, что показывал портал.
INSERT INTO problem_resolutions (id, name, action) VALUES
    ('7b000000-0000-4000-8000-000000000001', 'Списать',                 'write_off'),
    ('7b000000-0000-4000-8000-000000000002', 'Разместить в «Основной»', 'place'),
    ('7b000000-0000-4000-8000-000000000003', 'Возврат поставщику',      'supplier_return'),
    ('7b000000-0000-4000-8000-000000000004', 'Провести пересорт',       'regrade');

-- --- Причины ---------------------------------------------------------------------------------
--
-- Код причины - ключ, на который ссылаются проблемы (`warehouse_problems.reason`) и программа
-- (системные причины). Новой причине код выдаёт база: «c1», «c2» …
CREATE SEQUENCE problem_reasons_code_seq;

CREATE TABLE problem_reasons (
    code             text        PRIMARY KEY DEFAULT 'c' || nextval('problem_reasons_code_seq'),
    ord              bigint      GENERATED ALWAYS AS IDENTITY UNIQUE,
    name             text        NOT NULL CHECK (btrim(name) <> '' AND char_length(name) <= 100),
    -- Заводит программа, не выключается.
    is_system        boolean     NOT NULL DEFAULT false,
    -- Кладовщик выбирает её на ТСД при пометке. Нет - причину ставит только программа
    -- (выбытие марки, «не найдено», пересорт).
    manual           boolean     NOT NULL DEFAULT true,
    comment_required boolean     NOT NULL DEFAULT false,
    is_active        boolean     NOT NULL DEFAULT true,
    created_at       timestamptz NOT NULL DEFAULT now(),
    CHECK (is_active OR NOT is_system)
);
ALTER SEQUENCE problem_reasons_code_seq OWNED BY problem_reasons.code;
CREATE UNIQUE INDEX problem_reasons_name_uq ON problem_reasons (lower(name));

COMMENT ON TABLE problem_reasons IS
    'ADHOC-55: причина проблемы склада. Системные заводит программа; manual - выбирается на ТСД.';

INSERT INTO problem_reasons (code, name, is_system, manual, comment_required) VALUES
    ('breakage',     'Бой',                     false, true,  false),
    ('spoilage',     'Порча',                   false, true,  false),
    ('expired',      'Просрок',                 false, true,  false),
    ('foreign_mark', 'Не наша марка',           true,  true,  false),
    ('retired',      'Марка выбыла из оборота', true,  false, false),
    ('not_found',    'Не найдено пересчётом',   true,  false, false),
    ('regrade',      'Пересорт',                true,  false, false),
    ('other',        'Прочее',                  false, true,  true);

-- --- Допустимые варианты причины ---------------------------------------------------------------
CREATE TABLE problem_reason_resolutions (
    reason        text NOT NULL REFERENCES problem_reasons(code),
    resolution_id uuid NOT NULL REFERENCES problem_resolutions(id),
    PRIMARY KEY (reason, resolution_id)
);

-- Прежняя карта решений (решение 2026-10-21, CZ-05, P10-03, ADHOC-53).
INSERT INTO problem_reason_resolutions (reason, resolution_id)
SELECT m.reason, ('7b000000-0000-4000-8000-00000000000' || m.n)::uuid
FROM (VALUES
    ('breakage', 1),
    ('spoilage', 1), ('spoilage', 3),
    ('expired', 1), ('expired', 3),
    ('foreign_mark', 2), ('foreign_mark', 3),
    ('retired', 1), ('retired', 3),
    ('other', 1), ('other', 2), ('other', 3),
    ('not_found', 1), ('not_found', 2),
    ('regrade', 4)
) AS m(reason, n);

-- Пересорт отдельно от всего остального: вариант с действием regrade - только у причины regrade,
-- у неё - только такие варианты. Держит триггер: правило связывает две таблицы.
CREATE FUNCTION problem_reason_resolutions_check() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    IF ((SELECT action FROM problem_resolutions WHERE id = NEW.resolution_id) = 'regrade')
       <> (NEW.reason = 'regrade') THEN
        RAISE EXCEPTION 'вариант «пересорт» допустим только у причины «Пересорт»'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER problem_reason_resolutions_check
    BEFORE INSERT OR UPDATE ON problem_reason_resolutions
    FOR EACH ROW EXECUTE FUNCTION problem_reason_resolutions_check();

-- --- Проблема ссылается на справочник ------------------------------------------------------------
ALTER TABLE warehouse_problems DROP CONSTRAINT warehouse_problems_reason_check;
ALTER TABLE warehouse_problems
    ADD CONSTRAINT warehouse_problems_reason_fkey FOREIGN KEY (reason) REFERENCES problem_reasons(code),
    -- Выбранный вариант. Действие варианта остаётся и в `decision`: по нему проверяется форма
    -- решения (документ, поставщик), и оно не зависит от правок справочника.
    ADD COLUMN resolution_id uuid REFERENCES problem_resolutions(id);

UPDATE warehouse_problems SET resolution_id = CASE decision
    WHEN 'write_off'       THEN '7b000000-0000-4000-8000-000000000001'::uuid
    WHEN 'place'           THEN '7b000000-0000-4000-8000-000000000002'::uuid
    WHEN 'supplier_return' THEN '7b000000-0000-4000-8000-000000000003'::uuid
    WHEN 'regrade'         THEN '7b000000-0000-4000-8000-000000000004'::uuid
END
WHERE decision IS NOT NULL;

ALTER TABLE warehouse_problems ADD CONSTRAINT warehouse_problems_resolution_check
    CHECK ((decision IS NULL) = (resolution_id IS NULL));

COMMENT ON COLUMN warehouse_problems.resolution_id IS
    'ADHOC-55: вариант решения из справочника; decision - его действие на момент решения.';

-- --- Право «Настройки: причины проблем» -----------------------------------------------------------
-- Решение 2026-10-29: своё право в дереве; «Администратор» (системная должность) получает его сам.
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
    'portal.settings.warehouses', 'portal.settings.problem_reasons', 'portal.settings.users',
    'tsd.receipt', 'tsd.movement',
    'tsd.tasks.putaway', 'tsd.tasks.stocktake_count', 'tsd.tasks.stocktake_manage',
    'tsd.stock.view', 'tsd.stock.cz_marked', 'tsd.stock.regrade', 'tsd.stock_entry',
    'tsd.problems.view', 'tsd.problems.mark'
]::text[]);
