-- Откат ADHOC-23: документ-основание приёмки.
ALTER TABLE receipts
    DROP CONSTRAINT IF EXISTS receipts_doc_number_check,
    DROP COLUMN IF EXISTS doc_number,
    DROP COLUMN IF EXISTS doc_date;
