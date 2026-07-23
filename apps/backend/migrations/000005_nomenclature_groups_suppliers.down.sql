-- Откат P1-04. Сначала снимаем с goods колонки-ссылки (FK на группы/поставщиков),
-- возвращаем обычный индекс на code, затем удаляем таблицы.
ALTER TABLE goods DROP COLUMN IF EXISTS supplier_id;
ALTER TABLE goods DROP COLUMN IF EXISTS group_id;
ALTER TABLE goods DROP COLUMN IF EXISTS full_name;
ALTER TABLE goods DROP CONSTRAINT IF EXISTS goods_code_key;
CREATE INDEX goods_code_idx ON goods (code);

DROP TABLE IF EXISTS suppliers;
DROP TABLE IF EXISTS nomenclature_groups;
