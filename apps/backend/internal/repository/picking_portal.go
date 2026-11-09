package repository

import (
	"context"
	"fmt"
	"time"

	"craftwms/internal/model"
)

// Отбор заказов портала: условие WHERE — только эти константы, параметры — аргументами запроса.
const (
	portalOrdersByDate = `o.warehouse_id = $1::uuid AND o.registry_date = $2::date`
	portalOrderByID    = `o.id = $1::uuid`
)

// PortalOrders — заказы склада на дату накладной для списка портала «Сборка-отгрузка» (P8-03),
// включая удалённые в 1С (с пометкой). Порядок — живые раньше удалённых, затем номер сборки.
func (r *PickingRepository) PortalOrders(ctx context.Context, warehouseID string, date time.Time) ([]model.PickingPortalOrder, error) {
	return r.portalOrders(ctx, portalOrdersByDate, warehouseID, date)
}

// PortalDetails — заказы даты со строками, фактом, коробами и правками: выгрузка Excel (P8-03).
func (r *PickingRepository) PortalDetails(ctx context.Context, warehouseID string, date time.Time) ([]model.PickingPortalDetail, error) {
	orders, err := r.portalOrders(ctx, portalOrdersByDate, warehouseID, date)
	if err != nil {
		return nil, err
	}
	return r.portalDetails(ctx, orders)
}

// PortalOrder — один заказ для окна деталей портала. Нет такого заказа → ErrPickingOrderNotFound.
func (r *PickingRepository) PortalOrder(ctx context.Context, orderID string) (model.PickingPortalDetail, error) {
	orders, err := r.portalOrders(ctx, portalOrderByID, orderID)
	if err != nil {
		return model.PickingPortalDetail{}, err
	}
	if len(orders) == 0 {
		return model.PickingPortalDetail{}, model.ErrPickingOrderNotFound
	}
	out, err := r.portalDetails(ctx, orders)
	if err != nil {
		return model.PickingPortalDetail{}, err
	}
	return out[0], nil
}

// portalOrders — шапки заказов с итогами по условию cond (одна из констант portalOrder*).
//
// Исполнитель показывается только у заказа в работе: после «Завершить сборку» в колонке
// «собрал» — picked_by. План — живые строки; факт — все пики, кроме возвращённых на место (пик
// по строке, убранной реестром, тоже факт: его предстоит вернуть).
func (r *PickingRepository) portalOrders(ctx context.Context, cond string, args ...any) ([]model.PickingPortalOrder, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT o.id::text, o.number, o.registry_date, o.invoice_number, o.order_number, o.order_date,
		       o.direction, o.client, o.address, o.status, o.is_partial, o.has_unknown,
		       o.deleted_at IS NOT NULL, o.changed_after_shipment,
		       CASE WHEN o.status = 'in_progress' THEN coalesce(ua.full_name, '') ELSE '' END,
		       CASE WHEN o.status = 'in_progress' THEN o.taken_at END,
		       coalesce(up.full_name, ''), o.picked_at, o.shipped_at,
		       coalesce(l.cnt, 0), coalesce(l.plan, 0), coalesce(f.qty, 0)::text, coalesce(b.cnt, 0),
		       coalesce(rt.qty, 0)::text
		FROM picking_orders o
		LEFT JOIN users ua ON ua.id = o.assignee_id
		LEFT JOIN users up ON up.id = o.picked_by
		LEFT JOIN LATERAL (
			SELECT count(*) AS cnt, sum(plan_qty) AS plan FROM picking_order_lines
			WHERE order_id = o.id AND removed_at IS NULL
		) l ON true
		LEFT JOIN LATERAL (
			SELECT sum(qty) AS qty FROM picking_picks WHERE order_id = o.id AND state <> 'returned'
		) f ON true
		LEFT JOIN LATERAL (SELECT count(*) AS cnt FROM picking_boxes WHERE order_id = o.id AND dropped_at IS NULL) b ON true
		-- Вернуть на места (P9-07-1) — то же правило, что returnLines, одним запросом на все
		-- заказы: перенесённое сверх плана, у удалённого — и «в сборке»; у отгруженного — ничего.
		LEFT JOIN LATERAL (
			SELECT sum(greatest(x.moved - x.plan, 0) + x.open) AS qty FROM (
				SELECT CASE WHEN o.deleted_at IS NOT NULL OR ln.removed_at IS NOT NULL THEN 0 ELSE ln.plan_qty END AS plan,
				       coalesce(sum(p.qty) FILTER (WHERE p.state = 'moved'), 0) AS moved,
				       CASE WHEN o.deleted_at IS NOT NULL
				            THEN coalesce(sum(p.qty) FILTER (WHERE p.state = 'picking'), 0) ELSE 0 END AS open
				FROM picking_order_lines ln LEFT JOIN picking_picks p ON p.line_id = ln.id
				WHERE ln.order_id = o.id GROUP BY ln.id
			) x
		) rt ON o.status <> 'shipped'
		WHERE `+cond+`
		ORDER BY o.deleted_at IS NOT NULL, o.number`, args...)
	if err != nil {
		return nil, fmt.Errorf("заказы сборки для портала: %w", err)
	}
	defer rows.Close()
	var out []model.PickingPortalOrder
	for rows.Next() {
		var o model.PickingPortalOrder
		var fact, back string
		if err := rows.Scan(&o.ID, &o.Number, &o.RegistryDate, &o.InvoiceNumber, &o.OrderNumber, &o.OrderDate,
			&o.Direction, &o.Client, &o.Address, &o.Status, &o.IsPartial, &o.HasUnknown,
			&o.Deleted, &o.ChangedAfterShipment, &o.AssigneeName, &o.TakenAt,
			&o.PickedByName, &o.PickedAt, &o.ShippedAt,
			&o.Lines, &o.PlanQty, &fact, &o.Boxes, &back); err != nil {
			return nil, fmt.Errorf("заказ сборки для портала: %w", err)
		}
		if o.FactQty, err = parseQty(fact); err != nil {
			return nil, err
		}
		if o.ReturnLeft, err = parseQty(back); err != nil {
			return nil, err
		}
		out = append(out, o)
	}
	return out, rows.Err()
}

// portalDetails дополняет шапки строками с фактом, коробами и правками — четырьмя запросами на
// все заказы сразу, а не по запросу на заказ (выгрузка даты — сотни заказов).
func (r *PickingRepository) portalDetails(ctx context.Context, orders []model.PickingPortalOrder) ([]model.PickingPortalDetail, error) {
	ids := make([]string, len(orders))
	byOrder := make(map[string]*model.PickingPortalDetail, len(orders))
	out := make([]model.PickingPortalDetail, len(orders))
	for i, o := range orders {
		ids[i] = o.ID
		out[i].Order = o
		byOrder[o.ID] = &out[i]
	}
	if len(ids) == 0 {
		return out, nil
	}
	lineAt, err := r.portalLines(ctx, ids, byOrder)
	if err != nil {
		return nil, err
	}
	if err := r.portalFacts(ctx, ids, byOrder, lineAt); err != nil {
		return nil, err
	}
	if err := r.portalBoxes(ctx, ids, byOrder); err != nil {
		return nil, err
	}
	if err := r.portalChanges(ctx, ids, byOrder); err != nil {
		return nil, err
	}
	if err := r.portalEvents(ctx, ids, byOrder); err != nil {
		return nil, err
	}
	return out, nil
}

// lineRef — где строка лежит в ответе: заказ и индекс строки.
type lineRef struct {
	order string
	index int
}

// portalLines — строки плана заказов, и убранные реестром тоже: в деталях они видны
// зачёркнутыми. Наименование — из 1С, единица и «маркируемый» — из справочника.
func (r *PickingRepository) portalLines(ctx context.Context, ids []string, byOrder map[string]*model.PickingPortalDetail) (map[string]lineRef, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT l.order_id::text, l.id::text, l.line_no, l.good_code, l.good_name, l.good_id IS NOT NULL,
		       coalesce(g.uom, ''), coalesce(g.cz_marked, false),
		       l.batch_date, l.registry_cell, coalesce(c.address, ''),
		       l.plan_qty, l.removed_at IS NOT NULL, l.shortage
		FROM picking_order_lines l
		LEFT JOIN goods g ON g.id = l.good_id
		LEFT JOIN cells c ON c.id = l.cell_id
		WHERE l.order_id = ANY($1::uuid[])
		ORDER BY l.order_id, l.line_no`, ids)
	if err != nil {
		return nil, fmt.Errorf("строки заказов сборки для портала: %w", err)
	}
	defer rows.Close()
	lineAt := map[string]lineRef{}
	for rows.Next() {
		var orderID string
		var l model.PickingPortalLine
		if err := rows.Scan(&orderID, &l.ID, &l.LineNo, &l.GoodCode, &l.GoodName, &l.Known, &l.Uom, &l.CZMarked,
			&l.BatchDate, &l.RegistryCell, &l.CellAddress, &l.PlanQty, &l.Removed, &l.Shortage); err != nil {
			return nil, fmt.Errorf("строка заказа сборки для портала: %w", err)
		}
		d := byOrder[orderID]
		lineAt[l.ID] = lineRef{order: orderID, index: len(d.Lines)}
		d.Lines = append(d.Lines, l)
	}
	return lineAt, rows.Err()
}

// portalFacts — пики заказов, кроме возвращённых на место, с марками: партия (дата
// производства), ячейка-источник, короб отгрузки и кто взял. Порядок — по времени пика.
func (r *PickingRepository) portalFacts(ctx context.Context, ids []string, byOrder map[string]*model.PickingPortalDetail, lineAt map[string]lineRef) error {
	rows, err := r.pool.Query(ctx, `
		SELECT p.line_id::text, b.production_date, c.address, bx.seq, p.qty::text, p.state,
		       coalesce(u.full_name, ''), p.picked_at,
		       coalesce(array_agg(m.cis ORDER BY m.cis) FILTER (WHERE m.cis IS NOT NULL), '{}')
		FROM picking_picks p
		JOIN cells c ON c.id = p.source_cell_id
		JOIN batches b ON b.id = p.batch_id
		JOIN picking_boxes bx ON bx.load_unit_id = p.box_id
		LEFT JOIN users u ON u.id = p.picked_by
		LEFT JOIN picking_pick_marks m ON m.pick_id = p.id
		WHERE p.order_id = ANY($1::uuid[]) AND p.state <> 'returned'
		GROUP BY p.id, b.production_date, c.address, bx.seq, u.full_name
		ORDER BY p.picked_at, p.id`, ids)
	if err != nil {
		return fmt.Errorf("факт сборки для портала: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var lineID, qty string
		var f model.PickingPortalFact
		if err := rows.Scan(&lineID, &f.BatchDate, &f.CellAddress, &f.BoxSeq, &qty, &f.State,
			&f.PickedBy, &f.PickedAt, &f.Marks); err != nil {
			return fmt.Errorf("пик для портала: %w", err)
		}
		if f.Qty, err = parseQty(qty); err != nil {
			return err
		}
		ref, ok := lineAt[lineID]
		if !ok {
			continue
		}
		d := byOrder[ref.order]
		d.Lines[ref.index].Facts = append(d.Lines[ref.index].Facts, f)
	}
	return rows.Err()
}

// portalBoxes — короба отгрузки заказов по номеру.
func (r *PickingRepository) portalBoxes(ctx context.Context, ids []string, byOrder map[string]*model.PickingPortalDetail) error {
	rows, err := r.pool.Query(ctx, `
		SELECT order_id::text, seq, shipped_at FROM picking_boxes
		WHERE order_id = ANY($1::uuid[]) AND dropped_at IS NULL ORDER BY order_id, seq`, ids)
	if err != nil {
		return fmt.Errorf("короба сборки для портала: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var orderID string
		var b model.PickingPortalBox
		if err := rows.Scan(&orderID, &b.Seq, &b.ShippedAt); err != nil {
			return fmt.Errorf("короб сборки для портала: %w", err)
		}
		byOrder[orderID].Boxes = append(byOrder[orderID].Boxes, b)
	}
	return rows.Err()
}

// portalChanges — правки заказов повторными загрузками реестра, в порядке записи.
func (r *PickingRepository) portalChanges(ctx context.Context, ids []string, byOrder map[string]*model.PickingPortalDetail) error {
	rows, err := r.pool.Query(ctx, `
		SELECT order_id::text, kind, coalesce(good_code, ''), coalesce(good_name, ''), batch_date,
		       old_qty, new_qty, order_status, at
		FROM picking_order_changes
		WHERE order_id = ANY($1::uuid[]) ORDER BY seq`, ids)
	if err != nil {
		return fmt.Errorf("правки реестра для портала: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var orderID string
		var c model.PickingPortalChange
		if err := rows.Scan(&orderID, &c.Kind, &c.GoodCode, &c.GoodName, &c.BatchDate,
			&c.OldQty, &c.NewQty, &c.OrderStatus, &c.At); err != nil {
			return fmt.Errorf("правка реестра для портала: %w", err)
		}
		byOrder[orderID].Changes = append(byOrder[orderID].Changes, c)
	}
	return rows.Err()
}

// ForceReleaseOrder — старший смены снимает заказ с исполнителя из портала (P8-03): заказ в
// работе снова «новый» без исполнителя. Пики и короба остаются — следующий кладовщик продолжает с
// того же места; прежний на следующем действии получит «заказ не у вас в работе».
//
// Заказ уже «новый» — не ошибка (повтор, или кладовщик успел отказаться сам); собранный и
// отгруженный — ErrPickingOrderClosed. В журнал — кто снял (leadID) и с кого.
func (r *PickingRepository) ForceReleaseOrder(ctx context.Context, orderID, leadID string) error {
	return WithinTx(ctx, r.pool, func(q Querier) error {
		st, err := lockPickingOrder(ctx, q, orderID, 0)
		switch {
		case err != nil:
			return err
		case st.status == model.PickingStatusNew:
			return nil
		case st.status != model.PickingStatusInProgress:
			return model.ErrPickingOrderClosed
		}
		if _, err := q.Exec(ctx, `
			UPDATE picking_orders SET status = 'new', assignee_id = NULL, taken_at = NULL
			WHERE id = $1::uuid`, orderID); err != nil {
			return fmt.Errorf("снять заказ сборки с исполнителя: %w", err)
		}
		return addPickingEvent(ctx, q, orderID, leadID,
			pickingEvent{kind: model.PickingEventReleasedByLead, prevUser: st.assignee})
	})
}

// portalEvents — журнал событий заказов (P9-07) в порядке записи.
func (r *PickingRepository) portalEvents(ctx context.Context, ids []string, byOrder map[string]*model.PickingPortalDetail) error {
	rows, err := r.pool.Query(ctx, `
		SELECT e.order_id::text, e.kind, coalesce(u.full_name, ''), coalesce(pu.full_name, ''),
		       e.boxes, e.qty::text, e.at
		FROM picking_order_events e
		LEFT JOIN users u ON u.id = e.user_id
		LEFT JOIN users pu ON pu.id = e.prev_user_id
		WHERE e.order_id = ANY($1::uuid[]) ORDER BY e.seq`, ids)
	if err != nil {
		return fmt.Errorf("события заказов для портала: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var orderID string
		var qty *string
		var e model.PickingPortalEvent
		if err := rows.Scan(&orderID, &e.Kind, &e.UserName, &e.PrevName, &e.Boxes, &qty, &e.At); err != nil {
			return fmt.Errorf("событие заказа для портала: %w", err)
		}
		if qty != nil {
			v, err := parseQty(*qty)
			if err != nil {
				return err
			}
			e.Qty = &v
		}
		byOrder[orderID].Events = append(byOrder[orderID].Events, e)
	}
	return rows.Err()
}
