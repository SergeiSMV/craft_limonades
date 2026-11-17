-- P9-07: журнал событий заказа сборки, завершение сборки и отгрузка.
--
-- У заказа хранится только текущее состояние (кто держит, кто собрал, кто отгрузил): кто брал
-- заказ до перехвата, кто от него отказался и кого снял старший смены, - терялось. Журнал нужен
-- отчётам (топ работников, топ отгрузок): каждое действие над заказом - строка, только
-- дописывается, пишется в той же транзакции, что и само действие. Правки реестра здесь не
-- повторяются - они в picking_order_changes.
CREATE TABLE picking_order_events (
    id           uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    seq          bigint        GENERATED ALWAYS AS IDENTITY UNIQUE,
    order_id     uuid          NOT NULL REFERENCES picking_orders(id) ON DELETE CASCADE,
    kind         text          NOT NULL CHECK (kind IN (
                     'taken',            -- взял свободный заказ
                     'taken_over',       -- перехватил зависший у другого (prev_user_id - у кого)
                     'released',         -- отказался сам
                     'released_by_lead', -- снял старший смены в портале (prev_user_id - с кого)
                     'completed',        -- «Завершить сборку» (boxes, qty - итог)
                     'reopened',         -- реестр добавил товар собранному: снова в работе (дособор)
                     'shipped'           -- отгружен сканом всех коробов (boxes, qty - итог)
                 )),
    user_id      uuid          NOT NULL REFERENCES users(id),  -- кто сделал
    prev_user_id uuid          REFERENCES users(id),           -- чей заказ перехватили или сняли
    boxes        int,                                          -- коробов у завершения и отгрузки
    qty          numeric(20,3),                                -- штук у завершения и отгрузки
    at           timestamptz   NOT NULL DEFAULT now(),

    CONSTRAINT picking_order_events_totals CHECK (
        (kind IN ('completed', 'shipped')) = (boxes IS NOT NULL AND qty IS NOT NULL))
);

CREATE INDEX picking_order_events_order_idx ON picking_order_events (order_id, seq);
-- Отчёты по работникам - по исполнителю и времени.
CREATE INDEX picking_order_events_user_idx ON picking_order_events (user_id, at);

COMMENT ON TABLE picking_order_events IS
    'P9-07: журнал событий заказа сборки (взял, отказался, снят, завершил, дособор, отгрузил).';

-- «Завершить сборку» ставит короба отгрузки в ячейку `ОТГРУЗКА` - строкой журнала размещений,
-- как любой перенос короба.
ALTER TABLE placements DROP CONSTRAINT placements_source_check;
ALTER TABLE placements ADD CONSTRAINT placements_source_check
    CHECK (source IN ('receipt','putaway','move','stock_entry','stocktake','picking'));

-- Пустой короб отгрузки (завели, но ничего не положили) «Завершить сборку» убирает из заказа,
-- остальные перенумеровывает 1…M - иначе ярлык «короб 2 из 3» при трёх коробах, один из которых
-- пустой, сбил бы отгрузку. Строку не удаляем: на короб могут ссылаться возвращённые пики.
-- Номер уникален только у живых коробов.
ALTER TABLE picking_boxes
    ADD COLUMN dropped_at timestamptz,
    DROP CONSTRAINT picking_boxes_order_id_seq_key;
CREATE UNIQUE INDEX picking_boxes_order_seq_uq ON picking_boxes (order_id, seq) WHERE dropped_at IS NULL;

COMMENT ON COLUMN picking_boxes.dropped_at IS
    'P9-07: пустой короб убран из заказа при «Завершить сборку»; номер свободен.';

SELECT add_data_version_triggers('picking_order_events', ARRAY['picking']);
