-- P3-02: откат статусов документа.
-- Отметки «скачан»/«выполнен» теряются: после отката все документы снова выглядят необработанными.
DROP INDEX IF EXISTS report_documents_status_created_at_idx;
ALTER TABLE report_documents
    DROP COLUMN IF EXISTS done_at,
    DROP COLUMN IF EXISTS downloaded_at,
    DROP COLUMN IF EXISTS status;
