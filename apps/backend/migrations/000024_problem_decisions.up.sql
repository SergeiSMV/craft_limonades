-- P6-07-3: решение офиса по проблеме склада - «списать», «разместить», «возврат поставщику».
--
-- Решения (2026-10-21). Решение принимается из портала по проблеме ЦЕЛИКОМ и проводится
-- кнопкой «Провести» - до неё остаток не меняется. Набор решений зависит от причины (список
-- в коде, `model.ProblemDecisionsFor`):
--   бой           - списать;
--   порча, просрок - списать / возврат поставщику;
--   не наша марка - разместить / возврат поставщику;
--   прочее        - списать / разместить / возврат поставщику.
--
-- «Списать»  - оператор указывает номер и дату документа списания 1С; товар уходит с остатка
--              WMS при проведении. Своего Excel WMS не формирует: документ живёт в 1С.
-- «Разместить» - метка снимается: товар возвращается в «Основной» на том же месте.
-- «Возврат поставщику» - товар переходит на системный склад «Возврат поставщику» и попадает
--              в открытое задание возврата своего поставщика (одно на поставщика, копит
--              возвраты до отгрузки). С остатка товар уходит при отгрузке на ТСД - отдельная
--              задача; здесь задание только рождается и наполняется.

-- --- Системные внутренние склады ------------------------------------------------------------
--
-- Склад, на который товар переводит сама программа, а не человек. Ищется по роли, а не по
-- коду: код и имя склада правятся из портала (ADHOC-29), а роль - нет. Системный склад нельзя
-- скрыть и удалить и нельзя выбрать на ТСД при пометке проблемы: туда переводит только
-- решение офиса.
ALTER TABLE internal_warehouses
    ADD COLUMN system_role text UNIQUE CHECK (system_role IN ('supplier_return'));

COMMENT ON COLUMN internal_warehouses.system_role IS
    'P6-07-3: роль системного склада (supplier_return - возврат поставщику). NULL - обычный '
    'склад. Системный не скрывается, не удаляется и не выбирается при пометке проблемы.';

-- Код RETURN мог уже завести admin из портала - тогда этот склад и становится системным.
INSERT INTO internal_warehouses (code, name, system_role)
VALUES ('RETURN', 'Возврат поставщику', 'supplier_return')
ON CONFLICT (code) DO UPDATE SET system_role = 'supplier_return', is_active = true;

-- --- Задание «Возврат поставщику» -----------------------------------------------------------
--
-- Одно открытое задание на поставщика склада: решения «возврат» копят в нём товар, пока склад
-- его не отгрузит. Позиции задания - проблемы, решённые возвратом (`warehouse_problems.
-- return_task_id`), с тем, что решение перевело на склад возврата (строки решения ниже).
ALTER TABLE warehouse_tasks DROP CONSTRAINT warehouse_tasks_kind_check;
ALTER TABLE warehouse_tasks
    ADD CONSTRAINT warehouse_tasks_kind_check CHECK (kind IN ('putaway','supplier_return')),
    ADD COLUMN supplier_id uuid REFERENCES suppliers(id),
    -- Кому везём - ровно у возврата.
    ADD CONSTRAINT warehouse_tasks_supplier_check CHECK ((kind = 'supplier_return') = (supplier_id IS NOT NULL));

CREATE UNIQUE INDEX warehouse_tasks_open_return_uq ON warehouse_tasks (warehouse_id, supplier_id)
    WHERE kind = 'supplier_return' AND status <> 'done';

-- --- Решение по проблеме --------------------------------------------------------------------
ALTER TABLE warehouse_problems
    ADD COLUMN decision       text        CHECK (decision IN ('write_off','place','supplier_return')),
    -- Документ списания 1С - ровно у списания.
    ADD COLUMN doc_number     text,
    ADD COLUMN doc_date       date,
    -- Кому возвращаем и в каком задании - ровно у возврата.
    ADD COLUMN supplier_id    uuid        REFERENCES suppliers(id),
    ADD COLUMN return_task_id uuid        REFERENCES warehouse_tasks(id),
    ADD COLUMN resolved_by    uuid        REFERENCES users(id),
    ADD COLUMN resolved_at    timestamptz,
    ADD CONSTRAINT warehouse_problems_resolved_check CHECK (
        (status = 'resolved') = (decision IS NOT NULL AND resolved_by IS NOT NULL AND resolved_at IS NOT NULL)),
    ADD CONSTRAINT warehouse_problems_write_off_check CHECK (
        COALESCE(decision = 'write_off', false) = (doc_number IS NOT NULL AND doc_date IS NOT NULL)),
    ADD CONSTRAINT warehouse_problems_return_check CHECK (
        COALESCE(decision = 'supplier_return', false) = (supplier_id IS NOT NULL AND return_task_id IS NOT NULL));

CREATE INDEX warehouse_problems_return_task_idx ON warehouse_problems (return_task_id)
    WHERE return_task_id IS NOT NULL;

-- --- Строки решения -------------------------------------------------------------------------
--
-- Что решение фактически взяло: товар партии с количеством в ячейке, из короба или россыпью.
-- Товар проблемы после пометки мог переехать (перемещение сохраняет метку), поэтому решение
-- берёт его там, где он лежит сейчас, и записывает откуда - это история ячейки для пересчёта
-- (P10) и место, откуда склад отгрузит возврат.
CREATE TABLE warehouse_problem_lines (
    id           uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    problem_id   uuid          NOT NULL REFERENCES warehouse_problems(id) ON DELETE CASCADE,
    line_no      int           NOT NULL,
    cell_id      uuid          NOT NULL REFERENCES cells(id),
    load_unit_id uuid          REFERENCES load_units(id),   -- короб проблемы; NULL - россыпь
    good_id      uuid          NOT NULL,
    batch_id     uuid          NOT NULL,
    qty          numeric(20,3) NOT NULL CHECK (qty > 0),
    UNIQUE (problem_id, line_no),
    FOREIGN KEY (batch_id, good_id) REFERENCES batches(id, good_id)
);

COMMENT ON TABLE warehouse_problem_lines IS
    'P6-07-3: что решение по проблеме взяло - товар партии с количеством, ячейка и короб.';
