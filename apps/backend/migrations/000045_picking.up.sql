-- P9-02: схема сборки и отгрузки по «Реестру» 1С.
--
-- Решения 2026-11-06 и 2026-11-08 (docs/picking.md). Реестр 1С за день загружается в портале;
-- документ сборки - пара «накладная + заказ», задание - заказ. Повторная загрузка той же даты
-- сверяется с прошлой: строки сравниваются по тройке «заказ + код товара + партия», правки
-- пишутся в историю. Резерва нет: пик ставит товар «в сборку», не трогая остаток ячейки
-- («20 шт. (5 шт. в сборке)»); «Завершить сборку» переносит остаток из ячеек в короба отгрузки,
-- короба - в служебную ячейку `ОТГРУЗКА`; «Отгрузить» сканом ярлыков всех коробов снимает
-- товар с остатка склада. Статусы - свои у WMS, статус из реестра не берётся.

-- --- Склад: откуда можно собирать, куда ставить собранное ----------------------------------

-- Галочка внутреннего склада «разрешить сборку» (решение 2026-11-08): из «Брака» и
-- «Изолятора» не собирают, а набор внутренних складов ведёт администратор. По умолчанию
-- запрещено - новый склад не попадёт в сборку, пока его не разрешат явно; разрешён склад по
-- умолчанию («Основной»).
ALTER TABLE internal_warehouses
    ADD COLUMN allow_picking boolean NOT NULL DEFAULT false;

UPDATE internal_warehouses SET allow_picking = true WHERE is_default;

COMMENT ON COLUMN internal_warehouses.allow_picking IS
    'P9-02: из товара этого склада можно собирать заказы (галочка в настройках склада).';

-- Ячейка отгрузки - служебная, как `ПРИЁМКА`: в ней числятся короба собранных заказов до
-- отгрузки. Одна на склад; в пересчёт и перемещение не входит (правила - в сервисах сборки).
ALTER TABLE cells
    ADD COLUMN is_shipping boolean NOT NULL DEFAULT false,
    ADD CONSTRAINT cells_shipping_not_default CHECK (NOT (is_shipping AND is_default));

CREATE UNIQUE INDEX cells_shipping_idx ON cells (warehouse_id) WHERE is_shipping;

COMMENT ON COLUMN cells.is_shipping IS
    'P9-02: ячейка отгрузки («ОТГРУЗКА») - короба собранных заказов до отгрузки. Одна на склад.';

INSERT INTO cells (warehouse_id, address, is_shipping)
SELECT id, 'ОТГРУЗКА', true FROM warehouses
ON CONFLICT (warehouse_id, address) DO UPDATE SET is_shipping = true, is_active = true;

-- Короб отгрузки уходит со склада вместе с заказом: статус shipped, места больше нет.
ALTER TABLE load_units DROP CONSTRAINT load_units_status_check;
ALTER TABLE load_units ADD CONSTRAINT load_units_status_check
    CHECK (status IN ('open','closed','placed','shipped'));

-- --- Загрузка реестра ------------------------------------------------------------------------

-- Каждая загрузка файла - строка: от неё отсчитываются правки документов («изменение в
-- реестре от <дата загрузки>»).
CREATE TABLE picking_loads (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    warehouse_id  uuid        NOT NULL REFERENCES warehouses(id),
    registry_date date        NOT NULL,                       -- дата накладных файла
    file_name     text        NOT NULL,
    uploaded_by   uuid        NOT NULL REFERENCES users(id),
    uploaded_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX picking_loads_date_idx ON picking_loads (warehouse_id, registry_date, uploaded_at);

-- --- Документ сборки: заказ ------------------------------------------------------------------

CREATE TABLE picking_orders (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Номер сборки для людей: «СБ-000001» (правило ADHOC-55: ни документа без номера).
    number           bigint      GENERATED ALWAYS AS IDENTITY UNIQUE,
    warehouse_id     uuid        NOT NULL REFERENCES warehouses(id),

    -- Шапка из реестра. registry_date - дата накладной = дата сборки, по ней календарь портала.
    registry_date    date        NOT NULL,
    invoice_number   text        NOT NULL,
    order_number     text        NOT NULL,
    order_date       date,
    direction        text        NOT NULL DEFAULT '',
    client           text        NOT NULL DEFAULT '',
    address          text        NOT NULL DEFAULT '',

    status           text        NOT NULL DEFAULT 'new'
                                 CHECK (status IN ('new','in_progress','picked','shipped')),
    -- new         - никто не взял;
    -- in_progress - взял кладовщик (дособор после правки реестра - тоже сюда);
    -- picked      - «Завершить сборку»: остаток в коробах отгрузки, короба в `ОТГРУЗКА`;
    -- shipped     - отсканированы ярлыки всех коробов, товар ушёл со склада.
    is_partial       boolean     NOT NULL DEFAULT false,   -- «собран частично»: была отметка «не хватает»
    has_unknown      boolean     NOT NULL DEFAULT false,   -- есть строки без товара в справочнике
    changed_after_shipment boolean NOT NULL DEFAULT false, -- реестр изменил или удалил отгруженный заказ

    -- Заказ пропал из реестра своей даты. Строка не удаляется: на неё ссылаются факт сборки и
    -- история, а заказ может вернуться следующей загрузкой.
    deleted_at       timestamptz,

    created_load_id  uuid        NOT NULL REFERENCES picking_loads(id),
    updated_load_id  uuid        NOT NULL REFERENCES picking_loads(id), -- последняя загрузка с заказом

    -- Исполнитель - один на заказ; зависание (8 ч без движения) и снятие старшим возвращают
    -- заказ в new без исполнителя, собранное остаётся в коробах.
    assignee_id      uuid        REFERENCES users(id),
    taken_at         timestamptz,
    last_activity_at timestamptz,
    picked_by        uuid        REFERENCES users(id),
    picked_at        timestamptz,                          -- последнее «Завершить сборку»
    shipped_by       uuid        REFERENCES users(id),
    shipped_at       timestamptz,

    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),

    -- Заказ всегда в одной накладной, повторная загрузка той же даты находит его по номеру.
    UNIQUE (warehouse_id, registry_date, order_number),
    CONSTRAINT picking_orders_assignee CHECK ((status = 'in_progress') = (assignee_id IS NOT NULL)),
    CONSTRAINT picking_orders_picked   CHECK (status NOT IN ('picked','shipped') OR picked_at IS NOT NULL),
    CONSTRAINT picking_orders_shipped  CHECK ((status = 'shipped') = (shipped_at IS NOT NULL)),
    CONSTRAINT picking_orders_after_shipment CHECK (NOT changed_after_shipment OR status = 'shipped')
);

-- Список ТСД - все несобранные заказы любой даты; портал - заказы выбранной даты.
CREATE INDEX picking_orders_open_idx ON picking_orders (warehouse_id, status)
    WHERE status IN ('new','in_progress') AND deleted_at IS NULL;
CREATE INDEX picking_orders_date_idx ON picking_orders (warehouse_id, registry_date);

CREATE TRIGGER picking_orders_set_updated_at
    BEFORE UPDATE ON picking_orders
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE picking_orders IS
    'P9-02: документ сборки - заказ реестра 1С (накладная + заказ), статусы WMS.';

-- --- Строки плана ----------------------------------------------------------------------------

-- Строка - тройка «код товара + партия» заказа: по ней сверяются повторные загрузки. Тройка,
-- повторённая в файле (одна партия из двух ячеек), сводится в строку с суммой количества и
-- первой ячейкой: смена ячейки изменением не считается, план всё равно сверяет её с остатком.
CREATE TABLE picking_order_lines (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id      uuid        NOT NULL REFERENCES picking_orders(id) ON DELETE CASCADE,
    line_no       int         NOT NULL,                      -- порядок строк заказа в файле
    good_code     text        NOT NULL,                      -- код в формате справочника
    good_name     text        NOT NULL DEFAULT '',           -- наименование из 1С, для показа
    good_id       uuid        REFERENCES goods(id),          -- NULL - кода нет в справочнике
    batch_date    date,                                      -- партия реестра; NULL - FEFO
    registry_cell text        NOT NULL DEFAULT '',           -- ячейка реестра как в файле
    cell_id       uuid        REFERENCES cells(id),          -- ячейка WMS по адресу реестра
    plan_qty      int         NOT NULL CHECK (plan_qty > 0),
    -- Строка пропала из реестра: план - ноль, взятое по ней возвращается на места. Строка не
    -- удаляется - на неё ссылается факт; вернётся следующей загрузкой - removed_at снимается.
    removed_at    timestamptz,
    shortage      boolean     NOT NULL DEFAULT false,        -- кладовщик отметил «не хватает»
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),

    UNIQUE (order_id, line_no),
    UNIQUE NULLS NOT DISTINCT (order_id, good_code, batch_date)
);

CREATE INDEX picking_order_lines_good_idx ON picking_order_lines (good_id);

CREATE TRIGGER picking_order_lines_set_updated_at
    BEFORE UPDATE ON picking_order_lines
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- --- История правок реестром -----------------------------------------------------------------

-- Что поменяла повторная загрузка: для окна деталей портала (добавлено, убавлено, удалено) и
-- для пометки «изменён в 1С после отгрузки». Только дописывается; порядок - по seq.
CREATE TABLE picking_order_changes (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    seq          bigint      GENERATED ALWAYS AS IDENTITY UNIQUE,
    order_id     uuid        NOT NULL REFERENCES picking_orders(id) ON DELETE CASCADE,
    load_id      uuid        NOT NULL REFERENCES picking_loads(id),
    kind         text        NOT NULL CHECK (kind IN (
                     'line_added',     -- новая строка
                     'line_removed',   -- строка пропала
                     'qty_changed',    -- изменилось количество
                     'order_deleted',  -- заказ пропал из реестра
                     'order_restored'  -- пропавший заказ вернулся
                 )),
    good_code    text,
    good_name    text,
    batch_date   date,
    old_qty      int,
    new_qty      int,
    order_status text        NOT NULL,   -- статус заказа в момент правки: что с ней делали
    at           timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT picking_order_changes_line CHECK (
        (kind IN ('order_deleted','order_restored')) = (good_code IS NULL))
);

CREATE INDEX picking_order_changes_order_idx ON picking_order_changes (order_id, seq);

-- --- Короба отгрузки -------------------------------------------------------------------------

-- Короб отгрузки - грузовая единица (load_units): ярлык с QR в формате ГЕ, скан короба на
-- отгрузке узнаётся как любой короб. seq - «короб 1 из N», N - число коробов заказа.
CREATE TABLE picking_boxes (
    load_unit_id uuid        PRIMARY KEY REFERENCES load_units(id),
    order_id     uuid        NOT NULL REFERENCES picking_orders(id),
    seq          int         NOT NULL CHECK (seq > 0),
    created_by   uuid        NOT NULL REFERENCES users(id),
    created_at   timestamptz NOT NULL DEFAULT now(),
    labels_printed int       NOT NULL DEFAULT 0,  -- сколько раз печатали ярлык: повтор - по праву
    shipped_by   uuid        REFERENCES users(id),
    shipped_at   timestamptz,                     -- ярлык отсканирован на отгрузке

    UNIQUE (order_id, seq)
);

-- --- Факт сборки -----------------------------------------------------------------------------

-- Пик - взятый товар: откуда, какой партии, в какой короб. Пока state = picking, остаток
-- числится в ячейке-источнике «в сборке»: доступно для перемещения, проблемы и пересчёта -
-- остаток минус открытые пики. «Завершить сборку» переносит остаток в короб (moved); возврат
-- на место - returned.
CREATE TABLE picking_picks (
    id                    uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id              uuid          NOT NULL REFERENCES picking_orders(id),
    line_id               uuid          NOT NULL REFERENCES picking_order_lines(id),
    box_id                uuid          NOT NULL REFERENCES picking_boxes(load_unit_id),
    good_id               uuid          NOT NULL,
    batch_id              uuid          NOT NULL,
    -- Источник: россыпь ячейки или короб хранения. Скан короба уже говорит, в какой он ячейке,
    -- - source_cell_id у короба пишется из его места в момент пика.
    source_cell_id        uuid          NOT NULL REFERENCES cells(id),
    source_load_unit_id   uuid          REFERENCES load_units(id),
    internal_warehouse_id uuid          NOT NULL REFERENCES internal_warehouses(id),
    qty                   numeric(20,3) NOT NULL CHECK (qty > 0),
    state                 text          NOT NULL DEFAULT 'picking'
                                        CHECK (state IN ('picking','moved','returned')),
    picked_by             uuid          NOT NULL REFERENCES users(id),
    picked_at             timestamptz   NOT NULL DEFAULT now(),
    moved_at              timestamptz,
    returned_at           timestamptz,

    FOREIGN KEY (batch_id, good_id) REFERENCES batches(id, good_id),
    CONSTRAINT picking_picks_moved    CHECK ((state = 'moved') = (moved_at IS NOT NULL) OR state = 'returned'),
    CONSTRAINT picking_picks_returned CHECK ((state = 'returned') = (returned_at IS NOT NULL))
);

-- «Сколько в сборке» у грани остатка - по открытым пикам.
CREATE INDEX picking_picks_open_idx ON picking_picks (source_cell_id, good_id, batch_id, internal_warehouse_id)
    WHERE state = 'picking';
CREATE INDEX picking_picks_order_idx ON picking_picks (order_id);
CREATE INDEX picking_picks_box_idx ON picking_picks (box_id);

-- Марки маркируемой позиции: количество пика - число его марок. Марка в открытом пике одна -
-- держит сервис сборки (марка остаётся на месте до «Завершить сборку»).
CREATE TABLE picking_pick_marks (
    pick_id uuid NOT NULL REFERENCES picking_picks(id) ON DELETE CASCADE,
    cis     text NOT NULL REFERENCES cz_marks(cis),
    PRIMARY KEY (pick_id, cis)
);

CREATE INDEX picking_pick_marks_cis_idx ON picking_pick_marks (cis);

-- --- Версии данных (ADHOC-60) ----------------------------------------------------------------

-- Своя область «picking»: список и детали сборки в портале и на ТСД. Пики меняют и «в сборке»
-- у остатка - поэтому и область содержимого склада.
INSERT INTO data_versions (domain) VALUES ('picking');

SELECT add_data_version_triggers('picking_loads',         ARRAY['picking']);
SELECT add_data_version_triggers('picking_orders',        ARRAY['picking']);
SELECT add_data_version_triggers('picking_order_lines',   ARRAY['picking']);
SELECT add_data_version_triggers('picking_order_changes', ARRAY['picking']);
SELECT add_data_version_triggers('picking_boxes',         ARRAY['picking']);
SELECT add_data_version_triggers('picking_picks',         ARRAY['picking', 'contents']);
SELECT add_data_version_triggers('picking_pick_marks',    ARRAY['picking', 'contents']);
