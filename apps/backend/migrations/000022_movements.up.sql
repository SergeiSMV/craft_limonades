-- P6-01: журнал движений — документ перемещения и пополнения со строками «откуда → куда».
--
-- Один документ на обе операции: перемещение и пополнение двигают одно и то же (ГЕ или товар
-- между ячейками и коробами) и уходят одним отчётом «Движение» (P5-04, P6-07). Различает их
-- вид документа, а не отдельные таблицы.
--
-- Как и размещение (P5-02), документ собирается на ТСД, в том числе без сети, и уходит одной
-- операцией очереди: сервер проводит его целиком в одной транзакции или не проводит вовсе.
-- Поэтому статуса «черновик» нет — на сервере документ появляется сразу проведённым.
--
-- Остаток по-прежнему живёт в `stock`, место ГЕ — в `load_units.cell_id` с историей
-- в `placements`. Эти таблицы — история того, что и как двигали: по ним строится отчёт и по
-- ним видно, что происходило с ячейкой и коробом после заданного момента (пересчёт, P10).

CREATE TABLE movements (
    -- Идентификатор ВЫДАЁТ УСТРОЙСТВО, как у приёмки и размещения: работа начинается на ТСД
    -- без сети. Повтор операции с тем же документом упирается в первичный ключ.
    id           uuid        PRIMARY KEY,

    kind         text        NOT NULL
                             CHECK (kind IN ('move','replenish')),
    -- move      — перемещение: ГЕ целиком или товар (из ячейки или короба — в ячейку или
    --             короб) по скану (P6-02, P6-03);
    -- replenish — пополнение: товар с количеством и партией, источник и приёмник — ГЕ или
    --             россыпь в любых сочетаниях (P6-05).

    warehouse_id uuid        NOT NULL REFERENCES warehouses(id),
    created_by   uuid        NOT NULL REFERENCES users(id),        -- кто двигал
    posted_at    timestamptz NOT NULL DEFAULT now()                -- момент проведения (время сервера)
);

CREATE INDEX movements_posted_at_idx ON movements (posted_at DESC);

COMMENT ON TABLE movements IS
    'P6-01: документ движения — перемещение (move) или пополнение (replenish). Проводится '
    'целиком одной операцией очереди.';

-- Строка движения: ГЕ целиком ЛИБО товар (товар · партия · количество · внутренний склад).
--
-- ГЕ хранится ссылкой, без состава: разворот в товарные строки делает отчёт «Движение» по
-- составу, прочитанному в транзакции проведения (пакет movement, P4-09-1) — как у размещения.
--
-- Товар берётся из ячейки или из короба в ней и кладётся в ячейку или в короб в ней:
-- `from_load_unit_id` / `to_load_unit_id` — короб-источник и короб-приёмник, NULL — россыпь.
-- Ячейки пишутся всегда, и у товара из короба тоже: строка самодостаточна для истории ячейки,
-- даже когда короб потом переедет.
CREATE TABLE movement_lines (
    id                    uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    movement_id           uuid          NOT NULL REFERENCES movements(id) ON DELETE CASCADE,
    line_no               int           NOT NULL,                     -- порядок строк, как на ТСД

    -- ГЕ целиком (перемещение).
    load_unit_id          uuid          REFERENCES load_units(id),

    -- Товар.
    good_id               uuid,
    batch_id              uuid,
    qty                   numeric(20,3),
    -- Учётная принадлежность (ADR-0016) — часть грани остатка: без неё не понять, чей товар
    -- переехал, когда в ячейке лежит и «Основной», и «Брак» (изоляция брака, P6-07).
    internal_warehouse_id uuid          REFERENCES internal_warehouses(id),
    from_load_unit_id     uuid          REFERENCES load_units(id),    -- из короба; NULL — из россыпи
    to_load_unit_id       uuid          REFERENCES load_units(id),    -- в короб; NULL — в россыпь

    from_cell_id          uuid          NOT NULL REFERENCES cells(id), -- откуда взяли
    to_cell_id            uuid          NOT NULL REFERENCES cells(id), -- куда положили

    UNIQUE (movement_id, line_no),

    -- ГЕ целиком ИЛИ товар — не оба и не ничего. У ГЕ целиком нет своих коробов-источника
    -- и приёмника: она сама и есть то, что едет.
    CHECK (
        (load_unit_id IS NOT NULL
            AND good_id IS NULL AND batch_id IS NULL AND qty IS NULL
            AND internal_warehouse_id IS NULL
            AND from_load_unit_id IS NULL AND to_load_unit_id IS NULL)
     OR (load_unit_id IS NULL
            AND good_id IS NOT NULL AND batch_id IS NOT NULL AND qty > 0
            AND internal_warehouse_id IS NOT NULL)
    ),
    -- ГЕ целиком на месте не переносится.
    CHECK (load_unit_id IS NULL OR from_cell_id <> to_cell_id),
    -- Товар обязан куда-то переехать: в другую ячейку или в другой короб. Внутри одной ячейки
    -- движение законно (из короба в россыпь рядом, из короба в короб) — такие «нулевые» строки
    -- не публикуются в отчёт (P6-07), но в истории остаются.
    CHECK (ROW(from_cell_id, from_load_unit_id) IS DISTINCT FROM ROW(to_cell_id, to_load_unit_id)),
    -- Партия существует И принадлежит товару строки (тот же приём, что у stock и lu_content).
    FOREIGN KEY (batch_id, good_id) REFERENCES batches(id, good_id)
);

CREATE INDEX movement_lines_movement_idx ON movement_lines (movement_id, line_no);
-- «Что уезжало из ячейки и что в неё приезжало» — история ячейки и проверка пересчёта (P10).
CREATE INDEX movement_lines_from_cell_idx ON movement_lines (from_cell_id);
CREATE INDEX movement_lines_to_cell_idx   ON movement_lines (to_cell_id);

COMMENT ON TABLE movement_lines IS
    'P6-01: строка движения — ГЕ целиком (load_unit_id) либо товар (товар · партия · qty · '
    'внутренний склад) из ячейки/короба в ячейку/короб.';

-- Журнал размещений ГЕ узнаёт перемещение: новый источник и ссылка на документ — как уже
-- ссылается на приёмку и размещение. Пополнение ГЕ не переносит, ему источник не нужен.
ALTER TABLE placements DROP CONSTRAINT placements_source_check;
ALTER TABLE placements ADD CONSTRAINT placements_source_check
    CHECK (source IN ('receipt','putaway','move'));
ALTER TABLE placements ADD COLUMN movement_id uuid REFERENCES movements(id);
