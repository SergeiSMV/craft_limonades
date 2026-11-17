-- P10-02: мягкая блокировка ячейки на пересчёте - движение через ячейку на подсчёте сбивает его.
--
-- Решение 2026-10-12: ячейку на подсчёте не запираем - склад работает, - но всё, что меняет её
-- содержимое после снимка, делает подсчёт негодным: ячейка уходит в `disrupted` и считается
-- заново. Содержимое ячейки меняют остаток (`stock`), состав короба (`lu_content`), место и склад
-- короба (`load_units`) и место марки (`cz_marks`). Пишут в них больше десятка мест кода, поэтому
-- правило живёт в базе триггерами: так его не обойдёт ни одна операция, нынешняя или будущая.
--
-- Гонка «снимок ↔ движение». Снимок читает ячейку в транзакции начала подсчёта; движение,
-- зафиксированное между чтением и фиксацией снимка, не попало бы ни в снимок, ни под пометку:
-- оно не видит ещё не зафиксированный `counting`. Поэтому обе стороны берут рекомендательную
-- блокировку ячейки: начало подсчёта - исключительную, движение - разделяемую. Движения друг
-- другу не мешают; начало подсчёта ждёт идущие движения ячейки и видит их результат, а движение,
-- начатое во время снятия снимка, дождётся его фиксации и пометит подсчёт сбитым.
-- Ключ - (1010, hashtext(ячейка)); совпадение хеша двух ячеек - лишь лишнее ожидание.

-- --- Пометка ячеек ---------------------------------------------------------------------------
CREATE FUNCTION stocktake_disrupt_cells(cells uuid[]) RETURNS void
    LANGUAGE plpgsql AS $$
DECLARE
    c uuid;
BEGIN
    FOREACH c IN ARRAY cells LOOP
        CONTINUE WHEN c IS NULL;
        PERFORM pg_advisory_xact_lock_shared(1010, hashtext(c::text));
        UPDATE stocktake_cells SET status = 'disrupted'
        WHERE cell_id = c AND status = 'counting';
    END LOOP;
END $$;

COMMENT ON FUNCTION stocktake_disrupt_cells(uuid[]) IS
    'P10-02: движение через ячейки - подсчёт идущих в них пересчётов сбит (counting → disrupted).';

-- --- Остаток ---------------------------------------------------------------------------------
CREATE FUNCTION stocktake_disrupt_on_stock() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    -- Строка, у которой не изменилось ни количество, ни грань, - не движение.
    IF TG_OP = 'UPDATE' AND OLD.qty = NEW.qty AND OLD.cell_id = NEW.cell_id
       AND OLD.internal_warehouse_id = NEW.internal_warehouse_id THEN
        RETURN NULL;
    END IF;
    IF TG_OP = 'INSERT' THEN
        PERFORM stocktake_disrupt_cells(ARRAY[NEW.cell_id]);
    ELSIF TG_OP = 'DELETE' THEN
        PERFORM stocktake_disrupt_cells(ARRAY[OLD.cell_id]);
    ELSE
        PERFORM stocktake_disrupt_cells(ARRAY[OLD.cell_id, NEW.cell_id]);
    END IF;
    RETURN NULL;
END $$;

CREATE TRIGGER stock_stocktake_disrupt
    AFTER INSERT OR UPDATE OR DELETE ON stock
    FOR EACH ROW EXECUTE FUNCTION stocktake_disrupt_on_stock();

-- --- Состав короба ---------------------------------------------------------------------------
--
-- Короб в ячейке тот же, а россыпь рядом с ним меняется: «вынуть из короба в россыпь» остатка
-- ячейки не трогает, но меняет то, что кладовщик считает.
CREATE FUNCTION stocktake_disrupt_on_lu_content() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND OLD.qty = NEW.qty AND OLD.load_unit_id = NEW.load_unit_id THEN
        RETURN NULL;
    END IF;
    PERFORM stocktake_disrupt_cells(ARRAY(
        SELECT cell_id FROM load_units
        WHERE id IN (
            CASE WHEN TG_OP <> 'INSERT' THEN OLD.load_unit_id END,
            CASE WHEN TG_OP <> 'DELETE' THEN NEW.load_unit_id END)));
    RETURN NULL;
END $$;

CREATE TRIGGER lu_content_stocktake_disrupt
    AFTER INSERT OR UPDATE OR DELETE ON lu_content
    FOR EACH ROW EXECUTE FUNCTION stocktake_disrupt_on_lu_content();

-- --- Место и склад короба --------------------------------------------------------------------
CREATE FUNCTION stocktake_disrupt_on_load_unit() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    PERFORM stocktake_disrupt_cells(ARRAY[OLD.cell_id, NEW.cell_id]);
    RETURN NULL;
END $$;

CREATE TRIGGER load_units_stocktake_disrupt
    AFTER UPDATE OF cell_id, internal_warehouse_id ON load_units
    FOR EACH ROW
    WHEN (OLD.cell_id IS DISTINCT FROM NEW.cell_id
          OR OLD.internal_warehouse_id IS DISTINCT FROM NEW.internal_warehouse_id)
    EXECUTE FUNCTION stocktake_disrupt_on_load_unit();

-- --- Место марки -----------------------------------------------------------------------------
--
-- Ячейка марки - своя (россыпь) или короба, в котором она лежит.
CREATE FUNCTION stocktake_disrupt_on_cz_mark() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        PERFORM stocktake_disrupt_cells(ARRAY[NEW.cell_id,
            (SELECT cell_id FROM load_units WHERE id = NEW.load_unit_id)]);
    ELSE
        PERFORM stocktake_disrupt_cells(ARRAY[OLD.cell_id, NEW.cell_id,
            (SELECT cell_id FROM load_units WHERE id = OLD.load_unit_id),
            (SELECT cell_id FROM load_units WHERE id = NEW.load_unit_id)]);
    END IF;
    RETURN NULL;
END $$;

CREATE TRIGGER cz_marks_stocktake_disrupt_insert
    AFTER INSERT ON cz_marks
    FOR EACH ROW EXECUTE FUNCTION stocktake_disrupt_on_cz_mark();

CREATE TRIGGER cz_marks_stocktake_disrupt_update
    AFTER UPDATE OF status, load_unit_id, cell_id, internal_warehouse_id ON cz_marks
    FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM NEW.status
          OR OLD.load_unit_id IS DISTINCT FROM NEW.load_unit_id
          OR OLD.cell_id IS DISTINCT FROM NEW.cell_id
          OR OLD.internal_warehouse_id IS DISTINCT FROM NEW.internal_warehouse_id)
    EXECUTE FUNCTION stocktake_disrupt_on_cz_mark();
