-- P5-02-1: задания для склада. Первый вид — размещение: оно создаётся при оприходовании
-- приёмки из того, что легло в ячейку приёмки, и выполняется сеансами размещения (P5-02).
--
-- Пул общий: задание без исполнителя видят все; взятое — только взявший. Зависшее задание
-- (по нему ничего не отправлено дольше заданного срока) снова видно всем как «новое» —
-- это решает запрос, а не фоновая задача: время само по себе ничего в базе не меняет.

CREATE TABLE warehouse_tasks (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Короткий номер для людей: «Задание №57». Идентификатор UUID человеку ничего не говорит.
    number           bigint      GENERATED ALWAYS AS IDENTITY UNIQUE,

    kind             text        NOT NULL CHECK (kind IN ('putaway')),   -- набор растёт: P10 — пересчёт
    status           text        NOT NULL DEFAULT 'new'
                                 CHECK (status IN ('new','in_progress','done')),
    -- new         — в пуле, взять может любой;
    -- in_progress — взято исполнителем (assignee_id), у других не видно, пока не зависло;
    -- done        — всё по заданию выполнено.

    warehouse_id     uuid        NOT NULL REFERENCES warehouses(id),
    -- Основание. Задание на размещение рождается из приёмки — по ней кладовщик и офис узнают,
    -- что это за товар. Одна приёмка — одно задание (уникальность ниже).
    receipt_id       uuid        REFERENCES receipts(id),

    assignee_id      uuid        REFERENCES users(id),     -- кто держит задание сейчас
    taken_at         timestamptz,                          -- когда взято
    -- Последнее действие по заданию: взятие или проведённый сеанс. От него считается «зависло».
    last_activity_at timestamptz,

    completed_by     uuid        REFERENCES users(id),     -- чей сеанс завершил задание
    completed_at     timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now(),

    -- Исполнитель есть ровно у взятого задания; момент завершения — ровно у выполненного.
    CHECK ((status = 'in_progress') = (assignee_id IS NOT NULL)),
    CHECK ((status = 'done') = (completed_at IS NOT NULL))
);

CREATE UNIQUE INDEX warehouse_tasks_receipt_kind_uq ON warehouse_tasks (receipt_id, kind)
    WHERE receipt_id IS NOT NULL;
-- Текущие задания — «всё, что не выполнено»; лента завершённых — по времени завершения.
CREATE INDEX warehouse_tasks_open_idx      ON warehouse_tasks (status) WHERE status <> 'done';
CREATE INDEX warehouse_tasks_completed_idx ON warehouse_tasks (completed_at DESC, id DESC)
    WHERE status = 'done';

COMMENT ON TABLE warehouse_tasks IS
    'P5-02-1: задание для склада (пул: new → in_progress → done). Вид putaway создаётся при '
    'оприходовании приёмки.';

-- Что разместить по заданию: короб целиком ЛИБО россыпь (товар · партия · количество).
-- Остаток задания не хранится: он считается как позиция минус проведённое сеансами
-- размещения этого задания — так он не может разойтись с тем, что реально перенесли.
CREATE TABLE putaway_task_items (
    id           uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id      uuid          NOT NULL REFERENCES warehouse_tasks(id) ON DELETE CASCADE,
    line_no      int           NOT NULL,

    load_unit_id uuid          REFERENCES load_units(id),
    good_id      uuid,
    batch_id     uuid,
    qty          numeric(20,3),

    UNIQUE (task_id, line_no),
    CHECK (
        (load_unit_id IS NOT NULL AND good_id IS NULL AND batch_id IS NULL AND qty IS NULL)
     OR (load_unit_id IS NULL AND good_id IS NOT NULL AND batch_id IS NOT NULL AND qty > 0)
    ),
    FOREIGN KEY (batch_id, good_id) REFERENCES batches(id, good_id)
);

CREATE INDEX putaway_task_items_task_idx ON putaway_task_items (task_id, line_no);

COMMENT ON TABLE putaway_task_items IS
    'P5-02-1: позиции задания на размещение — короб либо россыпь. Остаток считается по сеансам.';

-- Размещения без задания нет (решение 2026-10-07): сеанс всегда выполняет задание.
-- Колонка NOT NULL сразу: документов размещения на проде ещё нет — P5-02 выходит вместе с ней.
ALTER TABLE putaways ADD COLUMN task_id uuid NOT NULL REFERENCES warehouse_tasks(id);
CREATE INDEX putaways_task_idx ON putaways (task_id);

-- Приёмки, оприходованные до заданий, получают задание из того, что легло в их ячейку приёмки —
-- по тому же правилу, по которому его создаёт оприходование. Иначе их товар в зоне приёмки
-- остался бы без способа его разместить.
WITH src AS (
    SELECT r.id AS receipt_id, r.warehouse_id, rl.load_unit_id, rl.good_id, rl.batch_id, rl.qty,
           row_number() OVER (PARTITION BY r.id ORDER BY rl.load_unit_id NULLS LAST, rl.good_id, rl.batch_id) AS rn
    FROM receipts r
    JOIN receipt_lines rl ON rl.receipt_id = r.id
    JOIN cells c          ON c.id = rl.cell_id AND c.is_default
    WHERE r.status = 'posted'
),
tasks AS (
    INSERT INTO warehouse_tasks (kind, warehouse_id, receipt_id, created_at)
    SELECT DISTINCT 'putaway', s.warehouse_id, s.receipt_id, r.posted_at
    FROM src s JOIN receipts r ON r.id = s.receipt_id
    RETURNING id, receipt_id
),
boxes AS (
    -- Короб в нескольких строках приёмки — одна позиция задания.
    SELECT DISTINCT ON (s.receipt_id, s.load_unit_id) s.receipt_id, s.load_unit_id
    FROM src s WHERE s.load_unit_id IS NOT NULL
),
items AS (
    SELECT receipt_id, load_unit_id, NULL::uuid AS good_id, NULL::uuid AS batch_id, NULL::numeric AS qty
    FROM boxes
    UNION ALL
    SELECT receipt_id, NULL, good_id, batch_id, qty FROM src WHERE load_unit_id IS NULL
)
INSERT INTO putaway_task_items (task_id, line_no, load_unit_id, good_id, batch_id, qty)
SELECT t.id,
       row_number() OVER (PARTITION BY t.id ORDER BY i.load_unit_id NULLS LAST, i.good_id, i.batch_id),
       i.load_unit_id, i.good_id, i.batch_id, i.qty
FROM items i JOIN tasks t ON t.receipt_id = i.receipt_id;
