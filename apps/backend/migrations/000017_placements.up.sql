-- P5-01: журнал размещений грузовых единиц — где ГЕ лежит сейчас и где лежала раньше.
--
-- ТЕКУЩЕЕ место ГЕ уже хранится в `load_units.cell_id` (P4-01), его ставит приёмка. Второй копии
-- «текущего места» здесь намеренно нет: два источника истины расходятся. Эта таблица — история:
-- каждая строка фиксирует один перенос ГЕ в ячейку. Инвариант: `load_units.cell_id` равен
-- `to_cell_id` последней строки ГЕ; держит его единая функция размещения в репозитории, которая
-- пишет обе таблицы в одной транзакции.
--
-- Остатки по ячейкам по-прежнему живут в `stock` (P1-02): журнал отвечает «куда и когда двигали
-- короб», а не «сколько товара в ячейке».
CREATE TABLE placements (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

    -- ON DELETE CASCADE: ГЕ удаляют только до оприходования приёмки (короб, отброшенный на ТСД),
    -- а у такой ГЕ нет и истории. Если удаление однажды понадобится для размещённой ГЕ,
    -- осиротевшие строки журнала всё равно не на что было бы показать.
    load_unit_id uuid        NOT NULL REFERENCES load_units(id) ON DELETE CASCADE,

    -- Откуда. NULL — первое размещение: ГЕ появилась на складе (приёмка).
    from_cell_id uuid        REFERENCES cells(id),
    -- Куда. Убытие ГЕ со склада (отгрузка, P9) сюда пока не пишется — колонка ослабится вместе
    -- с отгрузкой, когда станет ясно, чем такое событие описывать.
    to_cell_id   uuid        NOT NULL REFERENCES cells(id),

    -- Какая операция перенесла ГЕ. Набор расширяется вместе с операциями (P6 — перемещение).
    source       text        NOT NULL
                             CHECK (source IN ('receipt','putaway')),
    -- receipt — приёмка положила короб на место (по умолчанию в дефолтную ячейку);
    -- putaway — размещение перенесло его в ячейку хранения (P5-02).

    -- Документ приёмки, если перенос сделала она. Своего документа у размещения нет —
    -- его следы живут в журнале операций и в отчёте «Движение» (P5-04).
    receipt_id   uuid        REFERENCES receipts(id),

    -- Кто перенёс. NULL допустим только для строк, восстановленных миграцией без автора.
    user_id      uuid        REFERENCES users(id),

    placed_at    timestamptz NOT NULL DEFAULT now(),

    CHECK (from_cell_id IS DISTINCT FROM to_cell_id)   -- перенос «на месте» — не перенос
);

-- История одной ГЕ — главный запрос к журналу (просмотр ГЕ по скану, P5-05).
CREATE INDEX placements_lu_idx   ON placements (load_unit_id, placed_at, id);
-- «Что и когда клали в эту ячейку» — разбор расхождений по ячейке.
CREATE INDEX placements_cell_idx ON placements (to_cell_id, placed_at);

COMMENT ON TABLE placements IS
    'P5-01: журнал размещений ГЕ (откуда → куда, кем, какой операцией). Текущее место — '
    'load_units.cell_id, равное to_cell_id последней строки ГЕ.';

-- Уже размещённые ГЕ получают первую строку истории — иначе инвариант нарушен с первого дня.
-- Размещала их только приёмка (P4-09), поэтому автор и документ восстанавливаются по строкам
-- оприходованной приёмки этой ГЕ; время — момент оприходования.
INSERT INTO placements (load_unit_id, from_cell_id, to_cell_id, source, receipt_id, user_id, placed_at)
SELECT DISTINCT ON (lu.id)
       lu.id, NULL, lu.cell_id, 'receipt', r.id, r.created_by, COALESCE(r.posted_at, lu.updated_at)
FROM load_units lu
LEFT JOIN receipt_lines rl ON rl.load_unit_id = lu.id
LEFT JOIN receipts r       ON r.id = rl.receipt_id AND r.status = 'posted'
WHERE lu.cell_id IS NOT NULL
ORDER BY lu.id, r.posted_at NULLS LAST;
