-- ADHOC-60: версии данных по областям - клиент перечитывает только то, что изменилось.
--
-- Что: у каждой области данных (номенклатура, ячейки, остатки, задания…) - счётчик версии.
-- Сервер отдаёт версии всех областей заголовком в каждом ответе; ТСД и портал сравнивают их со
-- своими и перечитывают только разошедшиеся области.
-- Зачем: свежие данные без WebSocket, брокера и фонового опроса (ADR-0018, рядом с ADR-0014):
-- опрос по таймеру сажает батарею ТСД, а запросы клиент и так делает постоянно.
-- Как: счётчик повышает триггер уровня оператора на таблицах области - в той же транзакции,
-- что и правка, поэтому новую версию не увидеть раньше самих данных. Триггер смотрит в таблицу
-- переходов и не трогает счётчик, если оператор не изменил ни одной строки: охранные UPDATE
-- «… WHERE условие», не нашедшие строк, не заставят клиентов перечитывать область.
-- Счётчик, а не время: у времени бывают совпадения и расхождения часов, а последовательность
-- (sequence) видна до фиксации транзакции - клиент мог бы забрать данные раньше, чем они есть.

CREATE TABLE data_versions (
    domain  text   PRIMARY KEY,
    version bigint NOT NULL DEFAULT 1
);

-- Области - это единицы перечитывания на клиентах, а не таблицы: таблица может входить в
-- несколько областей (пересчёт - и задание, и страница «Пересчёты» в портале).
INSERT INTO data_versions (domain) VALUES
    ('goods'),      -- номенклатура, группы, поставщики, штрихкоды
    ('cells'),      -- склады, ячейки, стеллажи
    ('settings'),   -- внутренние склады, причины проблем, должности, пользователи
    ('contents'),   -- остатки, партии, короба, марки ЧЗ - снимок склада
    ('tasks'),      -- задания для склада и их ход
    ('problems'),   -- проблемы склада
    ('stocktakes'), -- пересчёты
    ('documents');  -- документы для 1С

-- bump_data_version повышает версии областей из аргументов триггера, если оператор изменил хоть
-- одну строку. Таблица переходов называется changed у всех трёх триггеров таблицы - функция одна.
CREATE FUNCTION bump_data_version() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM changed) THEN
        UPDATE data_versions SET version = version + 1 WHERE domain = ANY (TG_ARGV);
    END IF;
    RETURN NULL;
END;
$$;

-- add_data_version_triggers вешает на таблицу три триггера уровня оператора (вставка, правка,
-- удаление) с таблицей переходов changed. Таблицу переходов нельзя объявить у триггера на
-- несколько событий сразу - поэтому три триггера, а не один.
CREATE FUNCTION add_data_version_triggers(tbl regclass, domains text[]) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    args text := (SELECT string_agg(quote_literal(d), ', ') FROM unnest(domains) d);
BEGIN
    EXECUTE format('CREATE TRIGGER data_version_ins AFTER INSERT ON %s REFERENCING NEW TABLE AS changed
                    FOR EACH STATEMENT EXECUTE FUNCTION bump_data_version(%s)', tbl, args);
    EXECUTE format('CREATE TRIGGER data_version_upd AFTER UPDATE ON %s REFERENCING NEW TABLE AS changed
                    FOR EACH STATEMENT EXECUTE FUNCTION bump_data_version(%s)', tbl, args);
    EXECUTE format('CREATE TRIGGER data_version_del AFTER DELETE ON %s REFERENCING OLD TABLE AS changed
                    FOR EACH STATEMENT EXECUTE FUNCTION bump_data_version(%s)', tbl, args);
END;
$$;

SELECT add_data_version_triggers('goods',                       ARRAY['goods']);
SELECT add_data_version_triggers('nomenclature_groups',         ARRAY['goods']);
SELECT add_data_version_triggers('suppliers',                   ARRAY['goods']);
SELECT add_data_version_triggers('barcodes',                    ARRAY['goods']);

SELECT add_data_version_triggers('warehouses',                  ARRAY['cells']);
SELECT add_data_version_triggers('cells',                       ARRAY['cells']);
SELECT add_data_version_triggers('racks',                       ARRAY['cells']);

SELECT add_data_version_triggers('internal_warehouses',         ARRAY['settings']);
SELECT add_data_version_triggers('problem_reasons',             ARRAY['settings']);
SELECT add_data_version_triggers('problem_reason_resolutions',  ARRAY['settings']);
SELECT add_data_version_triggers('positions',                   ARRAY['settings']);
SELECT add_data_version_triggers('users',                       ARRAY['settings']);

SELECT add_data_version_triggers('stock',                       ARRAY['contents']);
SELECT add_data_version_triggers('batches',                     ARRAY['contents']);
SELECT add_data_version_triggers('load_units',                  ARRAY['contents']);
SELECT add_data_version_triggers('lu_content',                  ARRAY['contents']);
SELECT add_data_version_triggers('cz_marks',                    ARRAY['contents']);
SELECT add_data_version_triggers('cz_aggregates',               ARRAY['contents']);

SELECT add_data_version_triggers('warehouse_tasks',             ARRAY['tasks']);
SELECT add_data_version_triggers('putaway_task_items',          ARRAY['tasks']);
SELECT add_data_version_triggers('task_events',                 ARRAY['tasks']);
SELECT add_data_version_triggers('putaways',                    ARRAY['tasks']);
SELECT add_data_version_triggers('supplier_return_shipments',   ARRAY['tasks']);

SELECT add_data_version_triggers('warehouse_problems',          ARRAY['problems']);
SELECT add_data_version_triggers('warehouse_problem_lines',     ARRAY['problems']);
SELECT add_data_version_triggers('problem_resolutions',         ARRAY['problems']);
SELECT add_data_version_triggers('problem_photos',              ARRAY['problems']);

-- Пересчёт - и задание (ход в «Текущих» на ТСД), и страница «Пересчёты» в портале.
SELECT add_data_version_triggers('stocktakes',                  ARRAY['stocktakes', 'tasks']);
SELECT add_data_version_triggers('stocktake_cells',             ARRAY['stocktakes', 'tasks']);
SELECT add_data_version_triggers('stocktake_scope',             ARRAY['stocktakes']);
SELECT add_data_version_triggers('stocktake_lines',             ARRAY['stocktakes']);
SELECT add_data_version_triggers('stocktake_marks',             ARRAY['stocktakes']);

SELECT add_data_version_triggers('report_documents',            ARRAY['documents']);
SELECT add_data_version_triggers('report_document_events',      ARRAY['documents']);
SELECT add_data_version_triggers('stock_entry_sessions',        ARRAY['documents']);
