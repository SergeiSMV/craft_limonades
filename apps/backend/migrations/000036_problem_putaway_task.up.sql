-- ADHOC-55: номер проблемы склада и задание на размещение по решению офиса «разместить».
--
-- 1. Номер проблемы. Ни операции, ни документа без номера: проблема — основание задания, и
--    называть её надо номером, а не причиной и датой. Номер — счётчик вида (как у заданий и
--    пересчётов); префикс («ПБ-000009») добавляет показ. Существующие проблемы нумеруются по
--    порядку заведения, дальше номер выдаёт identity.
ALTER TABLE warehouse_problems ADD COLUMN number bigint;
UPDATE warehouse_problems p SET number = n.rn
FROM (SELECT id, row_number() OVER (ORDER BY created_at, id) AS rn FROM warehouse_problems) n
WHERE n.id = p.id;
ALTER TABLE warehouse_problems ALTER COLUMN number SET NOT NULL;
ALTER TABLE warehouse_problems ALTER COLUMN number ADD GENERATED ALWAYS AS IDENTITY;
ALTER TABLE warehouse_problems ADD CONSTRAINT warehouse_problems_number_key UNIQUE (number);
-- Счётчик продолжает с последнего выданного: RESTART принимает только константу.
DO $$
BEGIN
    EXECUTE format('ALTER TABLE warehouse_problems ALTER COLUMN number RESTART WITH %s',
                   (SELECT COALESCE(max(number), 0) + 1 FROM warehouse_problems));
END $$;

COMMENT ON COLUMN warehouse_problems.number IS
    'ADHOC-55: номер проблемы для людей — счётчик вида, показ с префиксом «ПБ».';

-- 2. Задание на размещение по решению «разместить».
--
-- Что: задание на размещение получает второе основание — проблему склада (problem_id).
-- Зачем: решение «разместить» снимает метку на месте. Товар, который в этот момент лежит
--        в ячейке приёмки, становится «Основным» вне задания приёмки, а ячейку приёмки разносит
--        только задание. Без нового задания товар остался бы там навсегда.
-- Как: одно задание на проблему (частичный уникальный индекс); основание — либо приёмка,
--      либо проблема, и только у размещения.
ALTER TABLE warehouse_tasks ADD COLUMN problem_id uuid REFERENCES warehouse_problems(id);
ALTER TABLE warehouse_tasks
    ADD CONSTRAINT warehouse_tasks_problem_kind
    CHECK (problem_id IS NULL OR (kind = 'putaway' AND receipt_id IS NULL));
CREATE UNIQUE INDEX warehouse_tasks_problem_uq ON warehouse_tasks (problem_id)
    WHERE problem_id IS NOT NULL;

COMMENT ON COLUMN warehouse_tasks.problem_id IS
    'ADHOC-55: проблема-основание задания на размещение (решение «разместить» в ячейке приёмки).';
