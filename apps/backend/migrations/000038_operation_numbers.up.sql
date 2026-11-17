-- ADHOC-55: номер у каждой операции и каждого документа для 1С.
--
-- Правило пользователя: ни операции, ни документа без номера - номером на объект ссылаются в
-- разговоре, в поиске портала и в основании другого документа. В базе - число, счётчик вида;
-- префикс и шесть цифр добавляет показ («ПМ-000001»). Существующие записи нумеруются по
-- порядку проведения (заведения), дальше номер выдаёт база.
--
-- Счётчик у каждого вида свой:
--   приёмка ПР, размещение РЗ, ввод остатков ВО, отгрузка возврата ВП - identity таблицы;
--   перемещение ПМ и пополнение ПП - одна таблица movements, у каждого вида своя
--     последовательность, номер ставит триггер по виду;
--   документы 1С - одна таблица report_documents, у каждой формы своя последовательность:
--     «Поступление» ДП, «Движение» ДД, «Ввод остатков» ДВ, «Инвентаризация» ДИ.
-- Задания (ЗД), пересчёты (ИН) и проблемы (ПБ) номер уже имеют.

-- Приёмка - ПР, по времени заведения.
ALTER TABLE receipts ADD COLUMN number bigint;
UPDATE receipts x SET number = n.rn
FROM (SELECT id, row_number() OVER (ORDER BY created_at, id) AS rn FROM receipts) n
WHERE n.id = x.id;
ALTER TABLE receipts ALTER COLUMN number SET NOT NULL;
ALTER TABLE receipts ALTER COLUMN number ADD GENERATED ALWAYS AS IDENTITY;
ALTER TABLE receipts ADD CONSTRAINT receipts_number_key UNIQUE (number);
DO $$
BEGIN
    -- Счётчик продолжает с последнего выданного: RESTART принимает только константу.
    EXECUTE format('ALTER TABLE receipts ALTER COLUMN number RESTART WITH %s',
                   (SELECT COALESCE(max(number), 0) + 1 FROM receipts));
END $$;
COMMENT ON COLUMN receipts.number IS 'ADHOC-55: номер приёмки - счётчик вида, показ с префиксом «ПР».';

-- Размещение (сеанс по заданию) - РЗ, по времени проведения.
ALTER TABLE putaways ADD COLUMN number bigint;
UPDATE putaways x SET number = n.rn
FROM (SELECT id, row_number() OVER (ORDER BY posted_at, id) AS rn FROM putaways) n
WHERE n.id = x.id;
ALTER TABLE putaways ALTER COLUMN number SET NOT NULL;
ALTER TABLE putaways ALTER COLUMN number ADD GENERATED ALWAYS AS IDENTITY;
ALTER TABLE putaways ADD CONSTRAINT putaways_number_key UNIQUE (number);
DO $$
BEGIN
    -- Счётчик продолжает с последнего выданного: RESTART принимает только константу.
    EXECUTE format('ALTER TABLE putaways ALTER COLUMN number RESTART WITH %s',
                   (SELECT COALESCE(max(number), 0) + 1 FROM putaways));
END $$;
COMMENT ON COLUMN putaways.number IS 'ADHOC-55: номер сеанса размещения - счётчик вида, показ с префиксом «РЗ».';

-- Ввод остатков (сессия прохода) - ВО, по времени заведения.
ALTER TABLE stock_entry_sessions ADD COLUMN number bigint;
UPDATE stock_entry_sessions x SET number = n.rn
FROM (SELECT id, row_number() OVER (ORDER BY created_at, id) AS rn FROM stock_entry_sessions) n
WHERE n.id = x.id;
ALTER TABLE stock_entry_sessions ALTER COLUMN number SET NOT NULL;
ALTER TABLE stock_entry_sessions ALTER COLUMN number ADD GENERATED ALWAYS AS IDENTITY;
ALTER TABLE stock_entry_sessions ADD CONSTRAINT stock_entry_sessions_number_key UNIQUE (number);
DO $$
BEGIN
    -- Счётчик продолжает с последнего выданного: RESTART принимает только константу.
    EXECUTE format('ALTER TABLE stock_entry_sessions ALTER COLUMN number RESTART WITH %s',
                   (SELECT COALESCE(max(number), 0) + 1 FROM stock_entry_sessions));
END $$;
COMMENT ON COLUMN stock_entry_sessions.number IS 'ADHOC-55: номер сессии ввода остатков - счётчик вида, показ с префиксом «ВО».';

-- Отгрузка возврата поставщику - ВП, по времени проведения.
ALTER TABLE supplier_return_shipments ADD COLUMN number bigint;
UPDATE supplier_return_shipments x SET number = n.rn
FROM (SELECT id, row_number() OVER (ORDER BY posted_at, id) AS rn FROM supplier_return_shipments) n
WHERE n.id = x.id;
ALTER TABLE supplier_return_shipments ALTER COLUMN number SET NOT NULL;
ALTER TABLE supplier_return_shipments ALTER COLUMN number ADD GENERATED ALWAYS AS IDENTITY;
ALTER TABLE supplier_return_shipments ADD CONSTRAINT supplier_return_shipments_number_key UNIQUE (number);
DO $$
BEGIN
    -- Счётчик продолжает с последнего выданного: RESTART принимает только константу.
    EXECUTE format('ALTER TABLE supplier_return_shipments ALTER COLUMN number RESTART WITH %s',
                   (SELECT COALESCE(max(number), 0) + 1 FROM supplier_return_shipments));
END $$;
COMMENT ON COLUMN supplier_return_shipments.number IS 'ADHOC-55: номер отгрузки возврата - счётчик вида, показ с префиксом «ВП».';

-- Перемещение - ПМ, пополнение - ПП: свой счётчик у каждого вида.
CREATE SEQUENCE movements_move_number_seq;
CREATE SEQUENCE movements_replenish_number_seq;
ALTER TABLE movements ADD COLUMN number bigint;
UPDATE movements x SET number = n.rn
FROM (SELECT id, row_number() OVER (PARTITION BY kind ORDER BY posted_at, id) AS rn FROM movements) n
WHERE n.id = x.id;
ALTER TABLE movements ALTER COLUMN number SET NOT NULL;
ALTER TABLE movements ADD CONSTRAINT movements_number_key UNIQUE (kind, number);
SELECT setval('movements_move_number_seq', COALESCE((SELECT max(number) FROM movements WHERE kind = 'move'), 0) + 1, false);
SELECT setval('movements_replenish_number_seq', COALESCE((SELECT max(number) FROM movements WHERE kind = 'replenish'), 0) + 1, false);

-- Номер ставит база по виду: вставка без номера получает следующий номер своего счётчика.
CREATE FUNCTION movements_set_number() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.number := nextval(CASE NEW.kind
        WHEN 'move' THEN 'movements_move_number_seq'::regclass  -- ПМ
        WHEN 'replenish' THEN 'movements_replenish_number_seq'::regclass  -- ПП
        ELSE NULL::regclass
    END);
    RETURN NEW;
END $$;
CREATE TRIGGER movements_set_number BEFORE INSERT ON movements
    FOR EACH ROW EXECUTE FUNCTION movements_set_number();
COMMENT ON COLUMN movements.number IS 'ADHOC-55: номер документа движения - счётчик своего вида: перемещение «ПМ», пополнение «ПП».';

-- Документы для 1С - свой номер у формы.
CREATE SEQUENCE report_documents_receipt_number_seq;
CREATE SEQUENCE report_documents_movement_number_seq;
CREATE SEQUENCE report_documents_stock_entry_number_seq;
CREATE SEQUENCE report_documents_stocktake_number_seq;
ALTER TABLE report_documents ADD COLUMN number bigint;
UPDATE report_documents x SET number = n.rn
FROM (SELECT id, row_number() OVER (PARTITION BY kind ORDER BY created_at, id) AS rn FROM report_documents) n
WHERE n.id = x.id;
ALTER TABLE report_documents ALTER COLUMN number SET NOT NULL;
ALTER TABLE report_documents ADD CONSTRAINT report_documents_number_key UNIQUE (kind, number);
SELECT setval('report_documents_receipt_number_seq', COALESCE((SELECT max(number) FROM report_documents WHERE kind = 'receipt'), 0) + 1, false);
SELECT setval('report_documents_movement_number_seq', COALESCE((SELECT max(number) FROM report_documents WHERE kind = 'movement'), 0) + 1, false);
SELECT setval('report_documents_stock_entry_number_seq', COALESCE((SELECT max(number) FROM report_documents WHERE kind = 'stock_entry'), 0) + 1, false);
SELECT setval('report_documents_stocktake_number_seq', COALESCE((SELECT max(number) FROM report_documents WHERE kind = 'stocktake'), 0) + 1, false);

-- Номер ставит база по виду: вставка без номера получает следующий номер своего счётчика.
CREATE FUNCTION report_documents_set_number() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.number := nextval(CASE NEW.kind
        WHEN 'receipt' THEN 'report_documents_receipt_number_seq'::regclass  -- ДП
        WHEN 'movement' THEN 'report_documents_movement_number_seq'::regclass  -- ДД
        WHEN 'stock_entry' THEN 'report_documents_stock_entry_number_seq'::regclass  -- ДВ
        WHEN 'stocktake' THEN 'report_documents_stocktake_number_seq'::regclass  -- ДИ
        ELSE NULL::regclass
    END);
    RETURN NEW;
END $$;
CREATE TRIGGER report_documents_set_number BEFORE INSERT ON report_documents
    FOR EACH ROW EXECUTE FUNCTION report_documents_set_number();
COMMENT ON COLUMN report_documents.number IS 'ADHOC-55: номер документа 1С - счётчик своей формы: «Поступление» ДП, «Движение» ДД, «Ввод остатков» ДВ, «Инвентаризация» ДИ.';

-- Документы, сформированные до нумерации, получают номер своей операции в снимок: снимок
-- замораживает содержимое, а номер операции - ссылка на неё, он у неё уже есть. Без этого
-- документ в портале нельзя было бы найти по номеру операции.
UPDATE report_documents d SET snapshot = d.snapshot || jsonb_build_object('source_number', o.number)
FROM (
    SELECT 'receipt' AS source_type, id, number FROM receipts
    UNION ALL SELECT 'putaway', id, number FROM putaways
    UNION ALL SELECT 'movement', id, number FROM movements
    UNION ALL SELECT 'stock_entry_session', id, number FROM stock_entry_sessions
) o
WHERE d.source_type = o.source_type AND d.source_id = o.id AND NOT d.snapshot ? 'source_number';
