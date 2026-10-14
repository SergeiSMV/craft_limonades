-- Откат P6-07-1: «Проблемы склада».
--
-- Остаток, помеченный браком или изолятором, остаётся строками своих складов: склад короба
-- исчезает вместе с колонкой, и короб снова считается «Основным». «Изолятор» удаляется, только
-- если на нём нет остатка.
DROP TABLE IF EXISTS warehouse_problems;
ALTER TABLE load_units DROP COLUMN IF EXISTS internal_warehouse_id;
DELETE FROM internal_warehouses w
WHERE w.code = 'ISOLATOR'
  AND NOT EXISTS (SELECT 1 FROM stock s WHERE s.internal_warehouse_id = w.id);
DROP FUNCTION IF EXISTS default_internal_warehouse();
