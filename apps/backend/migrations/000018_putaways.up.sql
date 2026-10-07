-- P5-02: документ размещения — сеанс, в котором кладовщик разносит короба и россыпь из зоны
-- приёмки по ячейкам хранения.
--
-- Сеанс собирается на ТСД (в том числе без сети) и уходит одной операцией очереди: сервер
-- проводит его целиком в одной транзакции или не проводит вовсе. Поэтому статуса «черновик»
-- у документа нет — на сервере он появляется сразу проведённым.

CREATE TABLE putaways (
    -- Идентификатор ВЫДАЁТ УСТРОЙСТВО, как у приёмки: сеанс начинается на ТСД без сети.
    -- Повтор операции с тем же документом упирается в первичный ключ — второй раз сеанс
    -- не проводится.
    id           uuid        PRIMARY KEY,
    warehouse_id uuid        NOT NULL REFERENCES warehouses(id),
    created_by   uuid        NOT NULL REFERENCES users(id),        -- кто размещал
    posted_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX putaways_posted_at_idx ON putaways (posted_at DESC);

COMMENT ON TABLE putaways IS
    'P5-02: документ размещения (сеанс на ТСД). Проводится целиком одной операцией очереди.';

-- Строка размещения: короб целиком ЛИБО россыпь (товар · партия · количество).
--
-- Короб хранится ссылкой, без состава: разворот в товарные строки делает отчёт «Движение»
-- (P5-04) по составу, прочитанному в транзакции проведения (пакет movement, P4-09-1).
CREATE TABLE putaway_lines (
    id           uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    putaway_id   uuid          NOT NULL REFERENCES putaways(id) ON DELETE CASCADE,
    line_no      int           NOT NULL,                       -- порядок строк, как на ТСД

    load_unit_id uuid          REFERENCES load_units(id),
    good_id      uuid,
    batch_id     uuid,
    qty          numeric(20,3),

    from_cell_id uuid          NOT NULL REFERENCES cells(id),   -- откуда взяли
    to_cell_id   uuid          NOT NULL REFERENCES cells(id),   -- куда положили

    UNIQUE (putaway_id, line_no),
    -- Короб ИЛИ россыпь — не оба и не ничего.
    CHECK (
        (load_unit_id IS NOT NULL AND good_id IS NULL AND batch_id IS NULL AND qty IS NULL)
     OR (load_unit_id IS NULL AND good_id IS NOT NULL AND batch_id IS NOT NULL AND qty > 0)
    ),
    CHECK (from_cell_id <> to_cell_id),
    -- Партия существует И принадлежит товару строки (тот же приём, что у stock и lu_content).
    FOREIGN KEY (batch_id, good_id) REFERENCES batches(id, good_id)
);

CREATE INDEX putaway_lines_putaway_idx ON putaway_lines (putaway_id, line_no);

COMMENT ON TABLE putaway_lines IS
    'P5-02: строка размещения — короб целиком (load_unit_id) либо россыпь (товар · партия · qty).';

-- Журнал размещений ссылается на документ, который перенёс короб — как уже ссылается на приёмку.
ALTER TABLE placements ADD COLUMN putaway_id uuid REFERENCES putaways(id);
