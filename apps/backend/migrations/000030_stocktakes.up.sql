-- P10-01: схема пересчёта (инвентаризации).
--
-- Решения (2026-10-26). Пересчёт выборочный: область - ячейки, группа номенклатуры (в том числе
-- матрица: это узел дерева групп из выгрузки 1С), поставщик, товар, внутренний склад или весь
-- склад. Пересчёт разбивается на ячейки, и любой работник берёт ячейку и идёт её считать.
-- Ячейка считается целиком: снимок «ожидалось» и мягкая блокировка - в момент начала её
-- подсчёта (скан ячейки), а не при старте; движение через ячейку после этого помечает подсчёт
-- сбитым. Считается весь
-- физический остаток ячейки - каждая позиция со своим внутренним складом. Короб подтверждается
-- одним сканом целиком; вскрыть и пересчитать его - отдельное действие. Маркируемый товар
-- россыпью считается марками.

-- --- Документ пересчёта ----------------------------------------------------------------------
CREATE TABLE stocktakes (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Короткий номер для людей: «Пересчёт №12».
    number       bigint      GENERATED ALWAYS AS IDENTITY UNIQUE,
    warehouse_id uuid        NOT NULL REFERENCES warehouses(id),

    -- Область, как её задал старший смены: ячейки, группы номенклатуры (матрица - тоже группа),
    -- поставщики, товары, внутренние склады или весь склад. Сами объекты области - в
    -- stocktake_scope; «весь склад» объектов не имеет.
    scope_kind   text        NOT NULL
                             CHECK (scope_kind IN ('cells','group','supplier','good','internal_warehouse','all')),

    status       text        NOT NULL DEFAULT 'new'
                             CHECK (status IN ('new','in_progress','closed')),
    -- new         - заведён, ни одна ячейка ещё не считалась;
    -- in_progress - подсчёт ячеек идёт;
    -- closed      - закрыт: остаток приведён к факту (P10-03).

    created_by   uuid        NOT NULL REFERENCES users(id),
    created_at   timestamptz NOT NULL DEFAULT now(),
    closed_by    uuid        REFERENCES users(id),
    closed_at    timestamptz,

    CHECK ((status = 'closed') = (closed_at IS NOT NULL))
);

CREATE INDEX stocktakes_warehouse_idx ON stocktakes (warehouse_id, created_at DESC);

COMMENT ON TABLE stocktakes IS
    'P10-01: документ пересчёта - область, кто завёл и закрыл, статус new → in_progress → closed.';

-- --- Область пересчёта -----------------------------------------------------------------------
--
-- Что выбрал старший смены. Ровно один объект в строке; разворачивает область в ячейки P10-02.
-- Группа берётся с поддеревом: матрица - узел дерева групп. Строк нет - у «всего склада».
CREATE TABLE stocktake_scope (
    stocktake_id          uuid NOT NULL REFERENCES stocktakes(id) ON DELETE CASCADE,
    cell_id               uuid REFERENCES cells(id),
    group_id              uuid REFERENCES nomenclature_groups(id),
    supplier_id           uuid REFERENCES suppliers(id),
    good_id               uuid REFERENCES goods(id),
    internal_warehouse_id uuid REFERENCES internal_warehouses(id),
    CHECK (num_nonnulls(cell_id, group_id, supplier_id, good_id, internal_warehouse_id) = 1)
);

CREATE UNIQUE INDEX stocktake_scope_cell_uq     ON stocktake_scope (stocktake_id, cell_id)     WHERE cell_id IS NOT NULL;
CREATE UNIQUE INDEX stocktake_scope_group_uq    ON stocktake_scope (stocktake_id, group_id)    WHERE group_id IS NOT NULL;
CREATE UNIQUE INDEX stocktake_scope_supplier_uq ON stocktake_scope (stocktake_id, supplier_id) WHERE supplier_id IS NOT NULL;
CREATE UNIQUE INDEX stocktake_scope_good_uq     ON stocktake_scope (stocktake_id, good_id)     WHERE good_id IS NOT NULL;
CREATE UNIQUE INDEX stocktake_scope_iwh_uq      ON stocktake_scope (stocktake_id, internal_warehouse_id)
    WHERE internal_warehouse_id IS NOT NULL;

-- --- Ячейки пересчёта ------------------------------------------------------------------------
--
-- Ячейка - единица работы: любой работник берёт ячейку, идёт к ней и считает её целиком.
-- Взятая ячейка у других пропадает - двое к одной ячейке не пойдут. Снимок «ожидалось»
-- пишется в строки в момент начала подсчёта (started_at, скан ячейки на месте) - от этого же
-- момента движение через ячейку помечает подсчёт сбитым.
CREATE TABLE stocktake_cells (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    stocktake_id uuid        NOT NULL REFERENCES stocktakes(id) ON DELETE CASCADE,
    cell_id      uuid        NOT NULL REFERENCES cells(id),
    status       text        NOT NULL DEFAULT 'pending'
                             CHECK (status IN ('pending','taken','counting','counted','disrupted')),
    -- pending   - свободна, взять может любой;
    -- taken     - взята работником (taken_by), он идёт к ней;
    -- counting  - начата: снимок снят, ячейка на пересчёте (мягкая блокировка);
    -- counted   - подсчитана, факт по всем строкам зафиксирован;
    -- disrupted - во время подсчёта через ячейку прошло движение: подсчёт не годится,
    --             ячейку считают заново.
    taken_by     uuid        REFERENCES users(id),
    taken_at     timestamptz,
    started_at   timestamptz,
    counted_by   uuid        REFERENCES users(id),
    counted_at   timestamptz,
    UNIQUE (stocktake_id, cell_id),
    -- Кто держит ячейку - есть у всех, кроме свободной; снимок - с начала подсчёта.
    CHECK ((status = 'pending') = (taken_by IS NULL)),
    CHECK ((status IN ('pending','taken')) = (started_at IS NULL)),
    CHECK ((status = 'counted') = (counted_at IS NOT NULL))
);

-- «На пересчёте ли ячейка сейчас» - вопрос каждого движения через неё (мягкая блокировка).
CREATE INDEX stocktake_cells_counting_idx ON stocktake_cells (cell_id) WHERE status = 'counting';
-- «Мои ячейки» - что держит работник.
CREATE INDEX stocktake_cells_taken_idx ON stocktake_cells (taken_by) WHERE status IN ('taken','counting');

COMMENT ON TABLE stocktake_cells IS
    'P10-01: ячейка пересчёта: pending → counting (снимок, блокировка) → counted | disrupted.';

-- --- Строки: ожидалось и факт -----------------------------------------------------------------
--
-- Строка - позиция ячейки на своём внутреннем складе:
--   россыпь          - товар · партия, короба нет;
--   короб целиком    - короб, без товара: подтверждается сканом, количество 1 или 0;
--   товар в коробе   - короб · товар · партия: короб вскрыли и пересчитали.
-- expected_qty - снимок в момент начала подсчёта ячейки; 0 - позиции в снимке не было
-- (излишек). fact_qty - подтверждённый факт; NULL - ещё не подтверждена. Подсчитанная ячейка
-- без факта по строке - недостача: при подсчёте такие строки получают 0.
CREATE TABLE stocktake_lines (
    id                    uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    stocktake_cell_id     uuid          NOT NULL REFERENCES stocktake_cells(id) ON DELETE CASCADE,
    load_unit_id          uuid          REFERENCES load_units(id),
    good_id               uuid,
    batch_id              uuid,
    internal_warehouse_id uuid          NOT NULL REFERENCES internal_warehouses(id),
    expected_qty          numeric(20,3) NOT NULL DEFAULT 0 CHECK (expected_qty >= 0),
    fact_qty              numeric(20,3) CHECK (fact_qty >= 0),

    -- Товар и партия - вместе; без товара строка - это короб целиком, и количество у неё
    -- штучное: короб либо есть, либо нет.
    CHECK ((good_id IS NULL) = (batch_id IS NULL)),
    CHECK (good_id IS NOT NULL OR load_unit_id IS NOT NULL),
    CHECK (good_id IS NOT NULL OR (expected_qty IN (0, 1) AND (fact_qty IS NULL OR fact_qty IN (0, 1)))),
    FOREIGN KEY (batch_id, good_id) REFERENCES batches(id, good_id),

    UNIQUE NULLS NOT DISTINCT (stocktake_cell_id, load_unit_id, good_id, batch_id, internal_warehouse_id)
);

CREATE INDEX stocktake_lines_good_idx ON stocktake_lines (good_id) WHERE good_id IS NOT NULL;

COMMENT ON TABLE stocktake_lines IS
    'P10-01: строка пересчёта ячейки - россыпь, короб целиком или товар в коробе: ожидалось '
    '(снимок при начале подсчёта ячейки) и факт.';

-- --- Марки пересчёта --------------------------------------------------------------------------
--
-- Маркируемый товар россыпью считается марками (как в движении, CZ-06). Марка ожидалась -
-- лежала в ячейке россыпью в момент начала подсчёта; найдена - отсканирована. Ожидалась и не
-- найдена - «не найдено» при закрытии (P10-03); найдена и не ожидалась - излишек.
CREATE TABLE stocktake_marks (
    stocktake_cell_id uuid    NOT NULL REFERENCES stocktake_cells(id) ON DELETE CASCADE,
    cis               text    NOT NULL CHECK (cis ~ '^01[0-9]{14}21[^\x1d]+$'),
    line_id           uuid    NOT NULL REFERENCES stocktake_lines(id) ON DELETE CASCADE,
    expected          boolean NOT NULL DEFAULT false,
    found             boolean NOT NULL DEFAULT false,
    PRIMARY KEY (stocktake_cell_id, cis),
    CHECK (expected OR found)
);

CREATE INDEX stocktake_marks_line_idx ON stocktake_marks (line_id);

COMMENT ON TABLE stocktake_marks IS
    'P10-01: марки ЧЗ строки пересчёта россыпью: ожидалась (снимок) и найдена (скан).';

-- --- Задание на пересчёт ---------------------------------------------------------------------
--
-- Один пересчёт - одно задание в пуле «ЗАДАНИЯ». Его не берут целиком: оно общее, и работники
-- берут из него ячейки (stocktake_cells). Поэтому исполнителя у задания нет - оно остаётся
-- «новым», пока не подсчитаны все ячейки.
ALTER TABLE warehouse_tasks DROP CONSTRAINT warehouse_tasks_kind_check;
ALTER TABLE warehouse_tasks
    ADD CONSTRAINT warehouse_tasks_kind_check CHECK (kind IN ('putaway','supplier_return','stocktake'));
ALTER TABLE warehouse_tasks ADD COLUMN stocktake_id uuid REFERENCES stocktakes(id);
ALTER TABLE warehouse_tasks
    ADD CONSTRAINT warehouse_tasks_stocktake_kind CHECK ((kind = 'stocktake') = (stocktake_id IS NOT NULL));
CREATE UNIQUE INDEX warehouse_tasks_stocktake_uq ON warehouse_tasks (stocktake_id)
    WHERE stocktake_id IS NOT NULL;
