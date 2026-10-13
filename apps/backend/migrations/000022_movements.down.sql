-- Откат P6-01: журнал движений.
--
-- Строки журнала размещений с источником `move` остаются: без них `load_units.cell_id`
-- разошёлся бы с последней строкой истории ГЕ. Поэтому прежний набор источников возвращается
-- как NOT VALID — он действует для новых строк и не проверяет уже записанные. Теряется только
-- ссылка на документ перемещения.
ALTER TABLE placements DROP COLUMN IF EXISTS movement_id;
ALTER TABLE placements DROP CONSTRAINT IF EXISTS placements_source_check;
ALTER TABLE placements ADD CONSTRAINT placements_source_check
    CHECK (source IN ('receipt','putaway')) NOT VALID;

DROP TABLE IF EXISTS movement_lines;
DROP TABLE IF EXISTS movements;
