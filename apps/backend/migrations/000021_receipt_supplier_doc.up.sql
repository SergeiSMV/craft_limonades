-- ADHOC-23: документ-основание приёмки — номер и дата накладной поставщика.
--
-- Приёмка знала поставщика и дату оприходования, но не накладную, по которой товар пришёл.
-- Оператору в 1С нужен документ поставщика, а его дата может не совпадать с датой оприходования.
-- Оба поля обязательны (решение заказчика): накладной без номера кладовщик ставит «б/н».
ALTER TABLE receipts
    ADD COLUMN doc_number text,
    ADD COLUMN doc_date   date;

-- Уже лежащие приёмки — тестовые (БД очищается перед запуском полного контура): документа
-- у них нет, ставим «б/н» и дату оприходования, а у неоприходованных — дату создания.
UPDATE receipts
SET doc_number = 'б/н',
    doc_date   = COALESCE(posted_at, created_at)::date;

ALTER TABLE receipts
    ALTER COLUMN doc_number SET NOT NULL,
    ALTER COLUMN doc_date   SET NOT NULL,
    -- Номер — свободный текст (у поставщиков он с буквами и дробями), но не пустой и не
    -- простыня: 50 знаков с запасом хватает любому номеру накладной.
    ADD CONSTRAINT receipts_doc_number_check CHECK (char_length(btrim(doc_number)) BETWEEN 1 AND 50);

COMMENT ON COLUMN receipts.doc_number IS 'ADHOC-23: номер накладной поставщика; «б/н» — без номера';
COMMENT ON COLUMN receipts.doc_date   IS 'ADHOC-23: дата накладной поставщика';
