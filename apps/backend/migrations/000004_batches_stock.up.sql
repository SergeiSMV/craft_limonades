-- P1-02: партии (batches) и остатки (stock) — ядро учёта.
-- Партия = товар + дата выпуска (крипто-маркировки нет). Остаток — в разрезе
-- ячейка × товар × партия → количество. Триггер updated_at переиспользуем из 000001.

-- Партии. Партия принадлежит конкретному товару и определяется датой выпуска.
CREATE TABLE batches (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    good_id         uuid        NOT NULL REFERENCES goods(id),  -- товар-владелец партии
    production_date date        NOT NULL,                       -- дата выпуска = суть партии
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (good_id, production_date),   -- одна партия товара на дату выпуска
    UNIQUE (id, good_id)                 -- цель составного FK из stock (id уже PK; пара нужна, чтобы ссылаться на (id, good_id))
);
-- Индекс по good_id не заводим: UNIQUE(good_id, production_date) уже ведущий по good_id.

CREATE TRIGGER batches_set_updated_at
    BEFORE UPDATE ON batches
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Остатки. Грань — (ячейка, товар, партия) → количество. good_id держим денормализованно
-- (быстрый запрос «где и сколько товара X» без join к batches); согласованность с товаром
-- партии гарантирует составной FK ниже. Валидность good_id обеспечивается транзитивно
-- через batches.good_id → goods, поэтому отдельный FK stock.good_id → goods не нужен.
CREATE TABLE stock (
    id         uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    cell_id    uuid          NOT NULL REFERENCES cells(id),  -- ячейка хранения
    good_id    uuid          NOT NULL,                       -- товар (денормализован; см. составной FK)
    batch_id   uuid          NOT NULL,                       -- партия
    qty        numeric(20,3) NOT NULL CHECK (qty >= 0),      -- количество; дробное для uom='кг'; неотрицательное (backstop к атомарности P1-03)
    created_at timestamptz   NOT NULL DEFAULT now(),
    updated_at timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (cell_id, good_id, batch_id),   -- один остаток на (ячейка, товар, партия); ведущий cell_id → «что лежит в ячейке»
    -- Составной FK: партия существует И её товар совпадает со stock.good_id
    -- (страхует от рассинхронизации денормализованного good_id).
    FOREIGN KEY (batch_id, good_id) REFERENCES batches(id, good_id)
);

CREATE INDEX stock_good_id_idx  ON stock (good_id);   -- «где и сколько товара X» — главный учётный запрос
CREATE INDEX stock_batch_id_idx ON stock (batch_id);  -- остатки партии + обслуживание составного FK

CREATE TRIGGER stock_set_updated_at
    BEFORE UPDATE ON stock
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
