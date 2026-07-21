-- Откат P1-01. Порядок обратный зависимостям FK: сначала barcodes (→goods), затем goods,
-- потом cells (→warehouses) и warehouses. Триггеры и индексы удаляются вместе с таблицами.
DROP TABLE IF EXISTS barcodes;
DROP TABLE IF EXISTS goods;
DROP TABLE IF EXISTS cells;
DROP TABLE IF EXISTS warehouses;
