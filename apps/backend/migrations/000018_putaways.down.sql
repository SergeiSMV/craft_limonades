-- Откат P5-02: документ размещения. Строки журнала размещений остаются — теряют только ссылку.
ALTER TABLE placements DROP COLUMN IF EXISTS putaway_id;
DROP TABLE IF EXISTS putaway_lines;
DROP TABLE IF EXISTS putaways;
