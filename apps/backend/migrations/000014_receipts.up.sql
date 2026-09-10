-- P4-02: документ приёмки — шапка, строки, жизненный цикл по статусам.
--
-- Приёмка отличается от ввода остатков (P-FastStart) семантикой записи в остаток: ввод остатков
-- ФИКСИРУЕТ факт («в ячейке лежит столько»), а приёмка ДОБАВЛЯЕТ к тому, что уже есть. Поэтому
-- документ и его статусы нужны сами по себе: повторное оприходование удвоило бы остаток,
-- и защищает от этого именно статус, а не свойство операции.
CREATE TABLE receipts (
    -- Идентификатор ВЫДАЁТ УСТРОЙСТВО, как у сессии ввода остатков: приёмка начинается на ТСД,
    -- в том числе без сети, и серверный id взять было бы неоткуда — кладовщик не смог бы
    -- продолжить начатый документ.
    id           uuid        PRIMARY KEY,

    warehouse_id uuid        NOT NULL REFERENCES warehouses(id),   -- физический склад приёмки
    -- Поставщик известен не всегда: бывает внутреннее поступление и возврат. Пустое значение
    -- честнее, чем выдуманный «прочий поставщик», который потом попадёт в отчёт.
    supplier_id  uuid        REFERENCES suppliers(id),

    status       text        NOT NULL DEFAULT 'draft'
                             CHECK (status IN ('draft','posted')),
    -- draft  — набирается на ТСД, строки ещё меняются;
    -- posted — оприходован: остаток поднят, документ неизменен.

    created_by   uuid        NOT NULL REFERENCES users(id),        -- кто принимал
    posted_at    timestamptz,                                      -- когда оприходован
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

-- «Что сейчас в работе» и «приёмки за период» — рабочие списки на ТСД и в портале.
CREATE INDEX receipts_status_created_at_idx ON receipts (status, created_at DESC);
CREATE INDEX receipts_warehouse_idx         ON receipts (warehouse_id);

CREATE TRIGGER receipts_set_updated_at
    BEFORE UPDATE ON receipts
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE receipts IS
    'P4-02: документ приёмки. draft → posted; оприходование ДОБАВЛЯЕТ к остатку, поэтому повтор '
    'закрыт статусом, а не идемпотентностью операции.';

-- Строки приёмки: что, какой партии, сколько, куда и в какой грузовой единице.
CREATE TABLE receipt_lines (
    id           uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    receipt_id   uuid          NOT NULL REFERENCES receipts(id) ON DELETE CASCADE,
    good_id      uuid          NOT NULL,                      -- денормализован; см. составной FK
    batch_id     uuid          NOT NULL,
    cell_id      uuid          NOT NULL REFERENCES cells(id), -- куда кладём
    -- Грузовая единица необязательна: товар принимают и коробом, и россыпью (решение домена).
    -- ON DELETE SET NULL: расформировали короб — строка приёмки остаётся историей документа.
    load_unit_id uuid          REFERENCES load_units(id) ON DELETE SET NULL,
    qty          numeric(20,3) NOT NULL CHECK (qty > 0),      -- приход нулём смысла не имеет
    created_at   timestamptz   NOT NULL DEFAULT now(),
    updated_at   timestamptz   NOT NULL DEFAULT now(),

    -- Грань строки включает ячейку и ГЕ: один и тот же товар одной партии может приехать
    -- в двух коробах или лечь в две ячейки, и это разные строки документа. Повторный скан
    -- той же комбинации увеличивает количество, а не плодит строки.
    -- NULLS NOT DISTINCT: без него две россыпные строки (load_unit_id IS NULL) считались бы
    -- разными, и грань не работала бы там, где нужна чаще всего.
    -- Имя задано явно и коротко: автоимя из пяти колонок вылезает за 63 символа, Postgres его
    -- усекает, и ссылка на такое ограничение (например в COMMENT) перестаёт совпадать.
    CONSTRAINT receipt_lines_grain_key
        UNIQUE NULLS NOT DISTINCT (receipt_id, good_id, batch_id, cell_id, load_unit_id),

    -- Составной FK: партия существует И принадлежит тому же товару (приём из stock/lu_content).
    FOREIGN KEY (batch_id, good_id) REFERENCES batches(id, good_id)
);

CREATE INDEX receipt_lines_good_idx      ON receipt_lines (good_id);
CREATE INDEX receipt_lines_load_unit_idx ON receipt_lines (load_unit_id) WHERE load_unit_id IS NOT NULL;

CREATE TRIGGER receipt_lines_set_updated_at
    BEFORE UPDATE ON receipt_lines
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE receipt_lines IS
    'P4-02: строки приёмки (товар × партия × ячейка × ГЕ → количество). ГЕ необязательна.';
COMMENT ON CONSTRAINT receipt_lines_grain_key ON receipt_lines IS
    'Повторный скан той же комбинации увеличивает количество; NULLS NOT DISTINCT — чтобы грань '
    'работала и для россыпи, где ГЕ нет.';
