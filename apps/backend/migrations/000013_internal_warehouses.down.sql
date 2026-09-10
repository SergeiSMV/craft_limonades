-- P4-01-1: откат внутреннего склада как измерения остатка.
--
-- ⚠ Остатки разных внутренних складов в одной ячейке схлопываются: старая грань их не различает,
-- и вернуть её можно только после слияния. Количества складываются — это единственная трактовка,
-- сохраняющая физическое количество товара в ячейке; учётная принадлежность теряется безвозвратно.
--
-- Слияние и удаление идут ОДНИМ statement'ом с data-modifying CTE: подзапросы такого запроса
-- видят снимок таблицы на его начало, поэтому сумма считается по исходным строкам, а не по тому,
-- что осталось после удаления. Разбей это на два запроса — и сумма схлопнулась бы в количество
-- одной уцелевшей строки.
--
-- Оконные функции, а не GROUP BY с min(id): агрегата min() для uuid в Postgres нет, и такой
-- откат падал бы на первой же попытке.
WITH ranked AS (
    SELECT id,
           sum(qty)   OVER (PARTITION BY cell_id, good_id, batch_id)              AS total,
           row_number() OVER (PARTITION BY cell_id, good_id, batch_id ORDER BY id) AS rn
    FROM stock
), dropped AS (
    DELETE FROM stock s
    USING ranked r
    WHERE s.id = r.id AND r.rn > 1
    RETURNING s.id
)
UPDATE stock s
SET qty = r.total
FROM ranked r
WHERE s.id = r.id AND r.rn = 1;

DROP INDEX IF EXISTS stock_internal_warehouse_idx;
ALTER TABLE stock DROP CONSTRAINT IF EXISTS stock_cell_good_batch_iwh_key;
ALTER TABLE stock ADD CONSTRAINT stock_cell_id_good_id_batch_id_key UNIQUE (cell_id, good_id, batch_id);
ALTER TABLE stock DROP COLUMN IF EXISTS internal_warehouse_id;

DROP TABLE IF EXISTS internal_warehouses;
