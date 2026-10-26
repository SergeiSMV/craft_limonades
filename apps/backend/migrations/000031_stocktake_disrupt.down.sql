-- P10-02: снять мягкую блокировку ячеек на пересчёте.
DROP TRIGGER IF EXISTS cz_marks_stocktake_disrupt_update ON cz_marks;
DROP TRIGGER IF EXISTS cz_marks_stocktake_disrupt_insert ON cz_marks;
DROP TRIGGER IF EXISTS load_units_stocktake_disrupt ON load_units;
DROP TRIGGER IF EXISTS lu_content_stocktake_disrupt ON lu_content;
DROP TRIGGER IF EXISTS stock_stocktake_disrupt ON stock;

DROP FUNCTION IF EXISTS stocktake_disrupt_on_cz_mark();
DROP FUNCTION IF EXISTS stocktake_disrupt_on_load_unit();
DROP FUNCTION IF EXISTS stocktake_disrupt_on_lu_content();
DROP FUNCTION IF EXISTS stocktake_disrupt_on_stock();
DROP FUNCTION IF EXISTS stocktake_disrupt_cells(uuid[]);
