-- ADHOC-55: откат. Задания по проблемам остаются заданиями на размещение без основания:
-- по ним могли пройти сеансы размещения, удалять их нельзя.
DROP INDEX IF EXISTS warehouse_tasks_problem_uq;
ALTER TABLE warehouse_tasks DROP CONSTRAINT IF EXISTS warehouse_tasks_problem_kind;
ALTER TABLE warehouse_tasks DROP COLUMN IF EXISTS problem_id;

-- Номер проблемы: нумерации до ADHOC-55 не было.
ALTER TABLE warehouse_problems DROP COLUMN IF EXISTS number;
