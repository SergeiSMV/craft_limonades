-- P4-01-1 (ADR-0016): внутренний склад — измерение ОСТАТКА, а не свойство ячейки.
--
-- Зачем. Физический склад («Шабулина») держит ячейки с адресами. Внутренние склады — «Основной»,
-- «Брак» и сколько угодно ещё — это учётные категории, наложенные на те же самые ячейки: одна
-- физическая ячейка `M1-1-2-1` одновременно хранит товар основного склада и товар брака.
-- Если сделать внутренний склад свойством ячейки, такая ситуация становится невыразимой.
--
-- Справочник, а не enum: число внутренних складов произвольно, и пополнять его будут из портала
-- или приложения, а не миграцией. По той же причине в коде нет зашитых кодов вроде 'MAIN' —
-- «куда приходовать по умолчанию» отвечает флаг is_default, поэтому склад можно переименовать
-- или заменить другим, не трогая ни строчки кода.
CREATE TABLE internal_warehouses (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    code       text        NOT NULL UNIQUE,          -- короткий код для отчётов и импорта
    name       text        NOT NULL,                 -- как показывается человеку
    is_default boolean     NOT NULL DEFAULT false,   -- куда приходовать, если склад не выбран
    is_active  boolean     NOT NULL DEFAULT true,    -- скрыт из выбора; остатки на нём сохраняются
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- Ровно один склад по умолчанию: индекс по константе с условием — приём, дающий
-- «единственная строка с is_default = true» средствами БД, а не дисциплиной кода.
CREATE UNIQUE INDEX internal_warehouses_default_idx ON internal_warehouses ((true)) WHERE is_default;

CREATE TRIGGER internal_warehouses_set_updated_at
    BEFORE UPDATE ON internal_warehouses
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE internal_warehouses IS
    'P4-01-1 (ADR-0016): учётные категории остатка (основной, брак, …), наложенные на те же ячейки.';
COMMENT ON COLUMN internal_warehouses.is_default IS
    'Куда приходовать, если склад не выбран. Ровно один такой — частичный уникальный индекс.';

-- Стартовый состав: два склада, дальше справочник пополняется из интерфейса.
-- Данные, без которых система не работает (приходовать некуда), поэтому они в миграции,
-- а не в сиде: сид заводит администратора, а это часть схемы по смыслу.
INSERT INTO internal_warehouses (code, name, is_default) VALUES
    ('MAIN',   'Основной', true),
    ('DEFECT', 'Брак',     false);

-- --- Остаток получает новое измерение ---------------------------------------------------

ALTER TABLE stock ADD COLUMN internal_warehouse_id uuid REFERENCES internal_warehouses(id);

-- Бэкофилл: всё, что накоплено до этой миграции, принадлежит основному складу. Брака в системе
-- не было — его просто нечем было отметить.
UPDATE stock
SET internal_warehouse_id = (SELECT id FROM internal_warehouses WHERE is_default)
WHERE internal_warehouse_id IS NULL;

ALTER TABLE stock ALTER COLUMN internal_warehouse_id SET NOT NULL;

-- Грань остатка расширяется. Старая тройка не различала учётную принадлежность, поэтому
-- «основной» и «брак» в одной ячейке схлопывались в одну строку и затирали друг друга.
ALTER TABLE stock DROP CONSTRAINT stock_cell_id_good_id_batch_id_key;
ALTER TABLE stock ADD CONSTRAINT stock_cell_good_batch_iwh_key
    UNIQUE (cell_id, good_id, batch_id, internal_warehouse_id);

-- «Сколько всего этого товара на складе» — запрос, который теперь идёт поверх нового измерения
-- (итог по физическому складу = сумма по внутренним).
CREATE INDEX stock_internal_warehouse_idx ON stock (internal_warehouse_id);

COMMENT ON COLUMN stock.internal_warehouse_id IS
    'Учётная принадлежность остатка (ADR-0016). Физическое место — cell_id; одна ячейка держит '
    'остатки разных внутренних складов одновременно.';
