-- P6-07-1: «Проблемы склада» - пометка товара браком, изолятором и т. п.
--
-- Решения (2026-10-14). Брак - лишь метка и программная изоляция от «Основного»: товар остаётся
-- в той же ячейке и, как любой товар, перемещается. Метка - внутренний склад (ADR-0016): у
-- россыпи она уже есть (`stock.internal_warehouse_id`), у короба появляется здесь - на весь
-- состав сразу. Часть короба помечается выниманием в россыпь того же склада назначения.
-- Документа для 1С пометка не порождает: 1С узнает о браке решением офиса (P6-07-3).

-- --- Склад по умолчанию - функцией ---------------------------------------------------------
--
-- Значение по умолчанию для новых коробов. Подзапрос в DEFAULT запрещён, функция - нет; так
-- все места, где заводятся короба, не меняются: короб рождается «Основным».
CREATE FUNCTION default_internal_warehouse() RETURNS uuid
    LANGUAGE sql STABLE
    AS $$ SELECT id FROM internal_warehouses WHERE is_default $$;

-- --- Склад короба ----------------------------------------------------------------------------
--
-- Короб принадлежит одному внутреннему складу целиком: весь его состав лежит в остатке своей
-- ячейки строкой этого склада. Россыпь ячейки = остаток склада минус короба ЭТОГО склада.
-- Все существующие короба - «Основные»: брака не было, его нечем было отметить.
ALTER TABLE load_units
    ADD COLUMN internal_warehouse_id uuid NOT NULL DEFAULT default_internal_warehouse()
        REFERENCES internal_warehouses(id);

COMMENT ON COLUMN load_units.internal_warehouse_id IS
    'P6-07-1: внутренний склад короба целиком (основной, брак, изолятор …). Перенос короба '
    'сохраняет его; товар кладётся в короб только того же склада.';

-- «Изолятор» - для товара, который нельзя ни продавать, ни списывать до разбора: например,
-- не наша марка ЧЗ. Заводится здесь, чтобы ТСД было из чего выбрать; дальше склады заводит
-- портал (отдельная задача).
INSERT INTO internal_warehouses (code, name, is_default) VALUES ('ISOLATOR', 'Изолятор', false)
ON CONFLICT (code) DO NOTHING;

-- --- Проблема склада -------------------------------------------------------------------------
--
-- Запись о пометке: что (короб целиком ЛИБО товар - из россыпи или из короба), где, из
-- какого склада в какой, почему, кто и когда. Перевод остатка делается в той же транзакции
-- одной операцией очереди `problem_submit` - запись и движение остатка не расходятся.
CREATE TABLE warehouse_problems (
    -- Идентификатор ВЫДАЁТ УСТРОЙСТВО, как у приёмки и движения: фиксация работает без сети.
    -- Повтор операции упирается в первичный ключ.
    id                         uuid          PRIMARY KEY,
    warehouse_id               uuid          NOT NULL REFERENCES warehouses(id),
    cell_id                    uuid          NOT NULL REFERENCES cells(id),  -- где лежит товар

    -- Короб целиком: меняется склад короба, его состав переходит строкой нового склада.
    load_unit_id               uuid          REFERENCES load_units(id),

    -- Товар: партия и количество; из короба (from_load_unit_id) - вынимается в россыпь
    -- склада назначения той же ячейки, иначе - из россыпи.
    good_id                    uuid,
    batch_id                   uuid,
    qty                        numeric(20,3),
    from_load_unit_id          uuid          REFERENCES load_units(id),

    from_internal_warehouse_id uuid          NOT NULL REFERENCES internal_warehouses(id),
    to_internal_warehouse_id   uuid          NOT NULL REFERENCES internal_warehouses(id),

    -- Причина - фиксированный список (решение 2026-10-14): бой, порча, просрок, не наша марка,
    -- прочее. Склад назначения причина не диктует - его выбирает кладовщик.
    reason                     text          NOT NULL
                               CHECK (reason IN ('breakage','spoilage','expired','foreign_mark','other')),
    comment                    text          NOT NULL DEFAULT '',
    -- Марка ЧЗ (DataMatrix как отсканирована) - для «не нашей марки»; проверка марок - фаза CZ.
    mark                       text,

    -- Решение офиса - P6-07-3; пока проблема только открывается.
    status                     text          NOT NULL DEFAULT 'open'
                               CHECK (status IN ('open','resolved')),
    created_by                 uuid          NOT NULL REFERENCES users(id),
    created_at                 timestamptz   NOT NULL DEFAULT now(),

    CHECK (from_internal_warehouse_id <> to_internal_warehouse_id),
    -- Короб целиком ИЛИ товар - не оба и не ничего.
    CHECK (
        (load_unit_id IS NOT NULL
            AND good_id IS NULL AND batch_id IS NULL AND qty IS NULL AND from_load_unit_id IS NULL)
     OR (load_unit_id IS NULL
            AND good_id IS NOT NULL AND batch_id IS NOT NULL AND qty > 0)
    ),
    FOREIGN KEY (batch_id, good_id) REFERENCES batches(id, good_id)
);

-- Рабочий список офиса (P6-07-3): открытые сверху, свежие первыми.
CREATE INDEX warehouse_problems_status_idx ON warehouse_problems (status, created_at DESC);

COMMENT ON TABLE warehouse_problems IS
    'P6-07-1: проблема склада - пометка короба или товара другим внутренним складом (брак, '
    'изолятор) с причиной. Остаток переводится в той же транзакции; документа 1С нет.';
