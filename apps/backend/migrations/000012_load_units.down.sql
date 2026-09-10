-- P4-01: откат ГЕ и её состава. Порядок обратный созданию: сначала состав (ссылается на ГЕ),
-- затем сама ГЕ. CASCADE в определении таблицы тут не помогает — DROP идёт по зависимостям.
DROP TABLE IF EXISTS lu_content;
DROP TABLE IF EXISTS load_units;
