-- P5-02-1: журнал событий задания — кто и когда его брал, отдавал, выполнял.
--
-- Шапка задания хранит только текущее состояние: взятие повторным исполнителем перезаписывает
-- taken_at, отказ его стирает. Для разбора времени выполнения этого мало — не видно, что задание
-- брали трое, двое отказались и сколько оно провисело у каждого. Журнал только дописывается.
CREATE TABLE task_events (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Порядок записи. Время не годится: события одной транзакции (заход и завершение) получают
    -- одинаковое now(), и порядок между ними терялся бы.
    seq          bigint      GENERATED ALWAYS AS IDENTITY,
    task_id      uuid        NOT NULL REFERENCES warehouse_tasks(id) ON DELETE CASCADE,

    event        text        NOT NULL
                             CHECK (event IN ('created','taken','released','intercepted',
                                              'session','completed')),
    -- created     — задание заведено (приёмкой — автоматически, автора нет);
    -- taken       — взято в работу из пула;
    -- released    — исполнитель отказался, задание вернулось в пул;
    -- intercepted — взято у другого, у которого оно зависло (prev_user_id — у кого);
    -- session     — проведён заход размещения (putaway_id);
    -- completed   — всё по заданию выполнено.

    user_id      uuid        REFERENCES users(id),      -- кто; NULL — система
    prev_user_id uuid        REFERENCES users(id),      -- у кого перехвачено
    putaway_id   uuid        REFERENCES putaways(id),   -- заход
    at           timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX task_events_task_idx ON task_events (task_id, seq);

COMMENT ON TABLE task_events IS
    'P5-02-1: журнал событий задания (создано, взято, отказ, перехват, заход, завершено).';

-- Заданиям, заведённым до журнала, восстанавливается то, что о них известно: создание, текущее
-- взятие, заходы и завершение. Взятия и отказы до журнала не сохранились — их не было где хранить.
-- Одним запросом и по времени: порядок журнала задаёт seq, и он обязан совпасть с хронологией
-- (взятие могло случиться после частичного захода).
INSERT INTO task_events (task_id, event, user_id, putaway_id, at)
SELECT task_id, event, user_id, putaway_id, at FROM (
    SELECT id AS task_id, 'created' AS event, NULL::uuid AS user_id, NULL::uuid AS putaway_id,
           created_at AS at, 0 AS rank
    FROM warehouse_tasks
    UNION ALL
    SELECT id, 'taken', assignee_id, NULL, taken_at, 1 FROM warehouse_tasks
    WHERE status = 'in_progress' AND taken_at IS NOT NULL
    UNION ALL
    SELECT task_id, 'session', created_by, id, posted_at, 2 FROM putaways
    UNION ALL
    SELECT id, 'completed', completed_by, NULL, completed_at, 3 FROM warehouse_tasks
    WHERE status = 'done'
) ev
ORDER BY task_id, at, rank;
