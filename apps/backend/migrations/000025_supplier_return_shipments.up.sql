-- ADHOC-31: отгрузка возврата поставщику с ТСД.
--
-- Решения (2026-10-21). Задание «Возврат поставщику» (P6-07-3) склад отгружает целиком: сеанс
-- на ТСД - отметить позиции (скан короба / ячейки и товара или галочка в списке) и нажать
-- «Отгружено». Сеанс уходит одной операцией очереди `return_submit`, сервер проводит его
-- одной транзакцией: товар позиций уходит с остатка WMS, задание выполнено. Своего Excel WMS
-- не формирует - возврат оформляется в 1С по факту, офису достаточно выполненного задания.
--
-- Позиция задания - проблема, решённая возвратом. Отгружена - значит, у проблемы есть сеанс
-- отгрузки (`warehouse_problems.shipment_id`); позиция отгружается только целиком.

CREATE TABLE supplier_return_shipments (
    -- Идентификатор ВЫДАЁТ УСТРОЙСТВО, как у размещения: сеанс собирается без сети. Повтор
    -- операции упирается в первичный ключ.
    id           uuid        PRIMARY KEY,
    task_id      uuid        NOT NULL REFERENCES warehouse_tasks(id),
    warehouse_id uuid        NOT NULL REFERENCES warehouses(id),
    created_by   uuid        NOT NULL REFERENCES users(id),        -- кто отгрузил
    posted_at    timestamptz NOT NULL DEFAULT now()                -- время сервера
);

CREATE INDEX supplier_return_shipments_task_idx ON supplier_return_shipments (task_id);

COMMENT ON TABLE supplier_return_shipments IS
    'ADHOC-31: сеанс отгрузки возврата поставщику по заданию supplier_return.';

-- Что сеанс фактически снял с остатка: товар партии с количеством, ячейка и короб. Товар
-- склада возврата мог переехать после решения - сеанс берёт его там, где он лежит, и пишет
-- откуда: история ячейки для пересчёта (P10).
CREATE TABLE supplier_return_shipment_lines (
    id           uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    shipment_id  uuid          NOT NULL REFERENCES supplier_return_shipments(id) ON DELETE CASCADE,
    line_no      int           NOT NULL,
    problem_id   uuid          NOT NULL REFERENCES warehouse_problems(id),
    cell_id      uuid          NOT NULL REFERENCES cells(id),
    load_unit_id uuid          REFERENCES load_units(id),   -- короб позиции; NULL - россыпь
    good_id      uuid          NOT NULL,
    batch_id     uuid          NOT NULL,
    qty          numeric(20,3) NOT NULL CHECK (qty > 0),
    UNIQUE (shipment_id, line_no),
    FOREIGN KEY (batch_id, good_id) REFERENCES batches(id, good_id)
);

COMMENT ON TABLE supplier_return_shipment_lines IS
    'ADHOC-31: что сеанс отгрузки возврата снял с остатка - товар, партия, количество, ячейка.';

-- Позиция отгружена - у проблемы есть сеанс. Отгружается позиция один раз и только целиком.
ALTER TABLE warehouse_problems
    ADD COLUMN shipment_id uuid REFERENCES supplier_return_shipments(id),
    ADD CONSTRAINT warehouse_problems_shipment_check CHECK (
        shipment_id IS NULL OR decision = 'supplier_return');

-- Журнал задания: заход отгрузки - то же событие `session`, ссылкой на свой сеанс.
ALTER TABLE task_events
    ADD COLUMN shipment_id uuid REFERENCES supplier_return_shipments(id);
