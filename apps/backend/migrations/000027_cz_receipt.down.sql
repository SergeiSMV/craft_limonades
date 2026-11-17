-- Откат CZ-05: приёмка маркированного товара.
--
-- Проблемы с причиной «выбыла из оборота» становятся «прочим» с пояснением в комментарии:
-- удалять их нельзя (за ними остаток в «Изоляторе»), а старый CHECK такую причину не пустит.
-- Марки и остаток остаются как есть - откат схемы не откатывает складские факты.
DROP INDEX IF EXISTS cz_marks_problem_idx;
ALTER TABLE cz_marks DROP COLUMN IF EXISTS problem_id;

ALTER TABLE warehouse_problems DROP CONSTRAINT warehouse_problems_reason_check;
UPDATE warehouse_problems
SET reason = 'other',
    comment = CASE WHEN comment = '' THEN 'Марка ЧЗ выбыла из оборота'
                   ELSE comment || ' (марка ЧЗ выбыла из оборота)' END
WHERE reason = 'retired';
ALTER TABLE warehouse_problems ADD CONSTRAINT warehouse_problems_reason_check
    CHECK (reason IN ('breakage','spoilage','expired','foreign_mark','other'));

ALTER TABLE goods DROP COLUMN IF EXISTS cz_marked;
