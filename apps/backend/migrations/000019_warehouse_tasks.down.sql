-- Откат P5-02-1: задания для склада. Документы размещения теряют ссылку на задание.
DROP INDEX IF EXISTS putaways_task_idx;
ALTER TABLE putaways DROP COLUMN IF EXISTS task_id;
DROP TABLE IF EXISTS putaway_task_items;
DROP TABLE IF EXISTS warehouse_tasks;
