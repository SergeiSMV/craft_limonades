-- ADHOC-55: марки ЧЗ в строках операций.
--
-- Документ 1С по операции с маркируемым товаром называет каждую марку (строка на марку). До
-- сих пор марки строки ТСД присылал, сервер переносил их в cz_marks, но к строке операции не
-- сохранял - потом нельзя было сказать, какие марки прошли приёмкой, размещением или
-- перемещением. Колонка держит КИ марок строки россыпью или товара в короб/из короба. Короб,
-- перенесённый целиком, марок в строке не несёт: его марки - состав короба на момент операции,
-- снимок документа читает их в той же транзакции.
--
-- Строки до ADHOC-55 марок не знают - пустой массив.
ALTER TABLE receipt_lines  ADD COLUMN marks text[] NOT NULL DEFAULT '{}';
ALTER TABLE putaway_lines  ADD COLUMN marks text[] NOT NULL DEFAULT '{}';
ALTER TABLE movement_lines ADD COLUMN marks text[] NOT NULL DEFAULT '{}';

COMMENT ON COLUMN receipt_lines.marks  IS 'ADHOC-55: КИ марок ЧЗ строки приёмки.';
COMMENT ON COLUMN putaway_lines.marks  IS 'ADHOC-55: КИ марок ЧЗ строки размещения россыпью.';
COMMENT ON COLUMN movement_lines.marks IS 'ADHOC-55: КИ марок ЧЗ строки перемещения товара.';
