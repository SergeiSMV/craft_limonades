-- P-FS-01: слим-схема сессии ввода стартовых остатков (фаза P-FastStart).
-- Сессия = один документ «ввод остатков» (проход склада с ТСД). Строки копятся на ТСД локально,
-- на checkpoint'е ячейки уходят в сессию (durable), в `stock` пишутся только в финале (P-FS-04).
-- Триггер updated_at переиспользуем из 000001 (set_updated_at()).

-- Шапка документа ввода остатков.
CREATE TABLE stock_entry_sessions (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    warehouse_id uuid        NOT NULL REFERENCES warehouses(id),      -- склад, по которому идёт проход
    created_by   uuid        NOT NULL REFERENCES users(id),           -- кто вводил (для отчёта/аудита)
    status       text        NOT NULL DEFAULT 'draft'
                             CHECK (status IN ('draft','closed')),    -- draft = в работе, closed = финализирована
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    closed_at    timestamptz                                          -- момент финала; NULL, пока draft
);

-- Список документов склада (портал «Инвентаризация», волна 1b).
CREATE INDEX stock_entry_sessions_warehouse_id_idx ON stock_entry_sessions (warehouse_id);

CREATE TRIGGER stock_entry_sessions_set_updated_at
    BEFORE UPDATE ON stock_entry_sessions
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Строки документа: что и сколько по грани (ячейка × товар × партия=дата выпуска).
-- Здесь — «сырой» ввод сессии до финала; в `stock` строки переносятся SET-семантикой в P-FS-04.
CREATE TABLE stock_entry_lines (
    id              uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id      uuid          NOT NULL REFERENCES stock_entry_sessions(id) ON DELETE CASCADE, -- строки живут вместе с сессией
    cell_id         uuid          NOT NULL REFERENCES cells(id),
    good_id         uuid          NOT NULL REFERENCES goods(id),
    production_date date          NOT NULL,                    -- партия (дата выпуска); обязательна (решение C)
    qty             numeric(20,3) NOT NULL CHECK (qty >= 0),   -- итог по строке (SET, не приращение — решение B)
    created_at      timestamptz   NOT NULL DEFAULT now(),
    updated_at      timestamptz   NOT NULL DEFAULT now(),
    -- В рамках сессии строка на грань уникальна; повторный checkpoint той же грани перезаписывает
    -- строку (upsert-SET внутри сессии). Ведущий session_id → быстрый выбор «строки сессии».
    UNIQUE (session_id, cell_id, good_id, production_date)
);

CREATE TRIGGER stock_entry_lines_set_updated_at
    BEFORE UPDATE ON stock_entry_lines
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
