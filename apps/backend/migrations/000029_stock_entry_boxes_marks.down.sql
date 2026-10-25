-- Откат ADHOC-46. Короба, марки и остаток, заведённые финалом, остаются на складе — уходит только
-- то, что о них знает сессия: строки сессии в коробах, марки и короба сессии, ссылка журнала.

ALTER TABLE placements DROP COLUMN IF EXISTS stock_entry_session_id;
-- Строки журнала с источником «ввод остатков» прежнее ограничение не примет. Это первая строка
-- короба: без неё он лежит в ячейке без истории, как короба до P5-01.
DELETE FROM placements WHERE source = 'stock_entry';
ALTER TABLE placements DROP CONSTRAINT placements_source_check;
ALTER TABLE placements ADD CONSTRAINT placements_source_check
    CHECK (source IN ('receipt','putaway','move'));

DROP TABLE IF EXISTS stock_entry_marks;

-- Строки в коробах прежняя грань не различит с россыпью — их нет и в прежней модели.
DELETE FROM stock_entry_lines WHERE load_unit_id IS NOT NULL;
ALTER TABLE stock_entry_lines DROP CONSTRAINT IF EXISTS stock_entry_lines_facet_key;
ALTER TABLE stock_entry_lines DROP CONSTRAINT IF EXISTS stock_entry_lines_load_unit_fkey;
ALTER TABLE stock_entry_lines DROP COLUMN IF EXISTS load_unit_id;
ALTER TABLE stock_entry_lines
    ADD UNIQUE (session_id, cell_id, good_id, production_date);

DROP TABLE IF EXISTS stock_entry_cz_groups;
DROP TABLE IF EXISTS stock_entry_load_units;
