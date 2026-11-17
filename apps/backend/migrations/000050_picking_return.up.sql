-- P9-07-1: возврат на места, когда реестр изменил или удалил заказ после сборки.
--
-- Лишнее сверх нового плана (у удалённого заказа - всё взятое) лежит в коробах отгрузки, а у
-- удалённого заказа «в работе» - ещё и «в сборке» у ячейки-источника. Его возвращает задание
-- «вернуть на места»: одно открытое на заказ. Позиций у задания нет - остаток считается на лету
-- по пикам и плану, поэтому повторная загрузка реестра сама уменьшает или снимает задание.

-- --- Задание «Вернуть на места» ---------------------------------------------------------------
ALTER TABLE warehouse_tasks DROP CONSTRAINT warehouse_tasks_kind_check;
ALTER TABLE warehouse_tasks
    ADD CONSTRAINT warehouse_tasks_kind_check
        CHECK (kind IN ('putaway','supplier_return','stocktake','picking_return')),
    ADD COLUMN picking_order_id uuid REFERENCES picking_orders(id),
    -- Заказ-основание - ровно у возврата на места.
    ADD CONSTRAINT warehouse_tasks_picking_kind
        CHECK ((kind = 'picking_return') = (picking_order_id IS NOT NULL));

CREATE UNIQUE INDEX warehouse_tasks_open_picking_uq ON warehouse_tasks (picking_order_id)
    WHERE kind = 'picking_return' AND status <> 'done';

COMMENT ON COLUMN warehouse_tasks.picking_order_id IS
    'P9-07-1: заказ сборки, по которому вернуть товар на места (вид picking_return).';

-- --- Возврат из короба отгрузки -----------------------------------------------------------------
--
-- Строка - одна операция очереди picking_return: сколько товара перенесённого пика ушло из
-- короба отгрузки в ячейку хранения. Пик при этом уменьшается (весь вернули - «возвращён»), так
-- что «перенесено» у пиков по-прежнему равно тому, что лежит в коробах. id выдаёт ТСД.
CREATE TABLE picking_returns (
    id          uuid          PRIMARY KEY,
    order_id    uuid          NOT NULL REFERENCES picking_orders(id),
    task_id     uuid          NOT NULL REFERENCES warehouse_tasks(id),
    pick_id     uuid          NOT NULL REFERENCES picking_picks(id),
    cell_id     uuid          NOT NULL REFERENCES cells(id),      -- куда вернули
    qty         numeric(20,3) NOT NULL CHECK (qty > 0),
    returned_by uuid          NOT NULL REFERENCES users(id),
    returned_at timestamptz   NOT NULL DEFAULT now()
);

CREATE INDEX picking_returns_order_idx ON picking_returns (order_id);
CREATE INDEX picking_returns_task_idx  ON picking_returns (task_id);

-- Марки маркируемого: какие марки вернулись в ячейку.
CREATE TABLE picking_return_marks (
    return_id uuid NOT NULL REFERENCES picking_returns(id) ON DELETE CASCADE,
    cis       text NOT NULL REFERENCES cz_marks(cis),
    PRIMARY KEY (return_id, cis)
);

COMMENT ON TABLE picking_returns IS
    'P9-07-1: возврат товара из короба отгрузки в ячейку хранения по заданию «вернуть на места».';

-- --- Журнал заказа: возврат ----------------------------------------------------------------------
ALTER TABLE picking_order_events DROP CONSTRAINT picking_order_events_kind_check;
ALTER TABLE picking_order_events ADD CONSTRAINT picking_order_events_kind_check CHECK (kind IN (
    'taken', 'taken_over', 'released', 'released_by_lead', 'completed', 'reopened', 'shipped',
    'returned'   -- вернул на место по заданию (qty - сколько)
));
ALTER TABLE picking_order_events DROP CONSTRAINT picking_order_events_totals;
ALTER TABLE picking_order_events ADD CONSTRAINT picking_order_events_totals CHECK (
    (kind IN ('completed', 'shipped')) = (boxes IS NOT NULL)
    AND (kind IN ('completed', 'shipped', 'returned')) = (qty IS NOT NULL));

-- --- Право ----------------------------------------------------------------------------------------
-- «Задания: вернуть на места» - отдельное действие ТСД. «Администратор» получает его сам.
ALTER TABLE positions DROP CONSTRAINT positions_rights_check;
ALTER TABLE positions ADD CONSTRAINT positions_rights_check CHECK (rights <@ ARRAY[
    'portal.nomenclature.view', 'portal.nomenclature.import',
    'portal.stock.view',
    'portal.receipt.view', 'portal.receipt.download', 'portal.receipt.post',
    'portal.stocktake.view', 'portal.stocktake.manage',
    'portal.stocktake_doc.view', 'portal.stocktake_doc.download', 'portal.stocktake_doc.post',
    'portal.stock_entry_doc.view', 'portal.stock_entry_doc.download', 'portal.stock_entry_doc.post',
    'portal.cells.import', 'portal.cells.labels', 'portal.cells.edit',
    'portal.movement.view', 'portal.movement.download', 'portal.movement.post',
    'portal.problems.view', 'portal.problems.resolve',
    'portal.picking.view', 'portal.picking.load', 'portal.picking.download', 'portal.picking.release',
    'portal.settings.warehouses', 'portal.settings.problem_reasons', 'portal.settings.users',
    'tsd.receipt', 'tsd.movement',
    'tsd.tasks.putaway', 'tsd.tasks.stocktake_count', 'tsd.tasks.stocktake_manage',
    'tsd.tasks.picking_return',
    'tsd.stock.view', 'tsd.stock.cz_marked', 'tsd.stock.regrade', 'tsd.stock_entry',
    'tsd.problems.view', 'tsd.problems.mark',
    'tsd.picking', 'tsd.picking.reprint'
]::text[]);

SELECT add_data_version_triggers('picking_returns', ARRAY['picking']);
