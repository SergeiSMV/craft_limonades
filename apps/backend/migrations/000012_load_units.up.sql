-- P4-01: грузовая единица (ГЕ) и её состав.
--
-- ГЕ - это короб или паллета, собранная на приёмке: физическая упаковка, которую дальше двигают
-- целиком. Она добровольна - товар можно принять и штучно (россыпью), поэтому ГЕ не заменяет
-- остаток, а живёт рядом с ним: `stock` отвечает «сколько товара в ячейке», `lu_content` -
-- «что лежит внутри этого короба».

-- Шапка ГЕ: чем является, где лежит, в каком состоянии.
CREATE TABLE load_units (
    -- Идентификатор ВЫДАЁТ УСТРОЙСТВО (UUID v4, P4-04) - он же кодируется в QR на ярлыке.
    -- Отдельной колонки `qr_id` намеренно нет: она хранила бы то же значение вторым экземпляром,
    -- а два источника истины расходятся. Тот же приём уже применён к сессии ввода остатков,
    -- где id тоже приходит с ТСД (иначе кладовщик не смог бы начать работу без сети).
    -- Если однажды понадобится сменить код при сохранении самой ГЕ (испорченный ярлык с новым
    -- номером), колонка добавится отдельной миграцией - сейчас такого сценария в объёме нет.
    id         uuid        PRIMARY KEY,

    kind       text        NOT NULL
                           CHECK (kind IN ('box','pallet')),   -- короб / паллета

    -- Вложенность: короб внутри паллеты. Паллетная логика отложена (вне объёма пилота), но поле
    -- заведено сразу - добавить его позже означало бы переписывать уже накопленные ГЕ.
    -- ON DELETE SET NULL: удаление паллеты не должно уносить вложенные короба, они физически есть.
    parent_id  uuid        REFERENCES load_units(id) ON DELETE SET NULL
                           CHECK (parent_id IS NULL OR parent_id <> id),  -- сама себе не родитель

    -- Где лежит. NULL - ГЕ собрана, но ещё не размещена (между приёмкой и размещением, P5).
    cell_id    uuid        REFERENCES cells(id),

    status     text        NOT NULL DEFAULT 'open'
                           CHECK (status IN ('open','closed','placed')),
    -- open   - собирается: в неё ещё кладут товар на приёмке;
    -- closed - собрана и закрыта, ждёт размещения;
    -- placed - размещена в ячейке (P5).

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- «Что лежит в этой ячейке» - главный вопрос при работе на складе; частичный индекс, потому что
-- у неразмещённых ГЕ ячейки нет и в этот запрос они не попадают.
CREATE INDEX load_units_cell_idx   ON load_units (cell_id) WHERE cell_id IS NOT NULL;
-- «Что вложено в эту паллету» - обход состава сверху вниз.
CREATE INDEX load_units_parent_idx ON load_units (parent_id) WHERE parent_id IS NOT NULL;
-- «Какие ГЕ ещё не размещены» - рабочий список после приёмки.
CREATE INDEX load_units_status_idx ON load_units (status);

CREATE TRIGGER load_units_set_updated_at
    BEFORE UPDATE ON load_units
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE load_units IS
    'P4-01: грузовая единица (короб/паллета). id приходит с устройства и кодируется в QR ярлыка.';
COMMENT ON COLUMN load_units.parent_id IS
    'Вложенность (короб в паллете). Паллетная логика вне объёма пилота, поле заведено заранее.';

-- Состав ГЕ: сколько какого товара какой партии лежит внутри.
CREATE TABLE lu_content (
    id           uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    load_unit_id uuid          NOT NULL REFERENCES load_units(id) ON DELETE CASCADE,
    good_id      uuid          NOT NULL,                       -- денормализован; см. составной FK
    batch_id     uuid          NOT NULL,
    qty          numeric(20,3) NOT NULL CHECK (qty >= 0),      -- дробное для uom='кг'
    created_at   timestamptz   NOT NULL DEFAULT now(),
    updated_at   timestamptz   NOT NULL DEFAULT now(),

    -- Одна строка на (ГЕ, товар, партия): повторное вложение того же товара той же партии
    -- увеличивает количество, а не плодит строки. Та же грань, что у остатка (P1-02).
    UNIQUE (load_unit_id, good_id, batch_id),

    -- Составной FK: партия существует И её товар совпадает с good_id строки - страховка от
    -- рассинхронизации денормализованного good_id (приём из `stock`).
    FOREIGN KEY (batch_id, good_id) REFERENCES batches(id, good_id)
);

-- Удаление ГЕ уносит её состав (CASCADE выше): пустая оболочка без содержимого смысла не имеет.
-- Индекс по товару - «в каких ГЕ лежит товар X».
CREATE INDEX lu_content_good_idx  ON lu_content (good_id);
CREATE INDEX lu_content_batch_idx ON lu_content (batch_id);

CREATE TRIGGER lu_content_set_updated_at
    BEFORE UPDATE ON lu_content
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE lu_content IS
    'P4-01: состав ГЕ (ГЕ × товар × партия → количество). Не заменяет stock: остаток отвечает '
    '«сколько товара в ячейке», состав - «что внутри этого короба».';
