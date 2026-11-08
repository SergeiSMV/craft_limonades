package repository

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"craftwms/internal/model"
)

// pickingShortageLockKey — пространство advisory-блокировок пересчёта по нехватке (P9-04); второй
// ключ — товар. Две отметки «не хватает» по одному товару не заводят два пересчёта.
const pickingShortageLockKey = 1041

// OpenOrders — список «СБОРКА» на ТСД (P9-04): все заказы «новый» и «в работе» любой даты, не
// удалённые в 1С. Заказ в работе у другого виден занятым, зависший (staleAfter без движения) —
// свободным. Порядок — дата накладной, затем номер сборки: сначала то, что отгружать раньше.
func (r *PickingRepository) OpenOrders(ctx context.Context, userID string, staleAfter time.Duration) ([]model.PickingOrderListItem, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT o.id::text, o.number, o.registry_date, o.invoice_number, o.order_number,
		       o.direction, o.client, o.address, o.status, o.has_unknown,
		       (SELECT count(*) FROM picking_order_lines l WHERE l.order_id = o.id AND l.removed_at IS NULL),
		       o.status = 'in_progress' AND o.assignee_id = $1::uuid,
		       o.status = 'in_progress' AND o.assignee_id <> $1::uuid
		           AND NOT coalesce(o.last_activity_at < now() - $2::interval, false),
		       coalesce(u.full_name, '')
		FROM picking_orders o
		LEFT JOIN users u ON u.id = o.assignee_id
		WHERE o.status IN ('new', 'in_progress') AND o.deleted_at IS NULL
		ORDER BY o.registry_date, o.number`, userID, intervalOf(staleAfter))
	if err != nil {
		return nil, fmt.Errorf("заказы сборки для ТСД: %w", err)
	}
	defer rows.Close()
	var out []model.PickingOrderListItem
	for rows.Next() {
		var it model.PickingOrderListItem
		if err := rows.Scan(&it.ID, &it.Number, &it.RegistryDate, &it.InvoiceNumber, &it.OrderNumber,
			&it.Direction, &it.Client, &it.Address, &it.Status, &it.HasUnknown,
			&it.Lines, &it.Mine, &it.Busy, &it.AssigneeName); err != nil {
			return nil, fmt.Errorf("заказ сборки для ТСД: %w", err)
		}
		out = append(out, it)
	}
	return out, rows.Err()
}

// pickingOrderState — состояние заказа под блокировкой строки.
type pickingOrderState struct {
	status     string
	deleted    bool
	hasUnknown bool
	assignee   *string
	stale      bool
}

// lockPickingOrder блокирует строку заказа до конца транзакции: двое, одновременно взявшие заказ,
// не запишут оба своё взятие, а действие по заказу не пройдёт мимо его снятия.
func lockPickingOrder(ctx context.Context, q Querier, orderID string, staleAfter time.Duration) (pickingOrderState, error) {
	var st pickingOrderState
	err := q.QueryRow(ctx, `
		SELECT status, deleted_at IS NOT NULL, has_unknown, assignee_id::text,
		       coalesce(last_activity_at < now() - $2::interval, false)
		FROM picking_orders WHERE id = $1::uuid FOR UPDATE`, orderID, intervalOf(staleAfter)).
		Scan(&st.status, &st.deleted, &st.hasUnknown, &st.assignee, &st.stale)
	if errors.Is(err, pgx.ErrNoRows) {
		return st, model.ErrPickingOrderNotFound
	}
	if err != nil {
		return st, fmt.Errorf("заказ сборки: %w", err)
	}
	return st, nil
}

// TakeOrder отдаёт заказ кладовщику: свободный, свой повторно или зависший у другого.
//
// Повтор своим исполнителем — не ошибка: кладовщик нажал «Взять» дважды или ответ не дошёл.
// Удалённый в 1С, с нераспознанными позициями, собранный и отгруженный не берутся.
func (r *PickingRepository) TakeOrder(ctx context.Context, orderID, userID string, staleAfter time.Duration) error {
	return WithinTx(ctx, r.pool, func(q Querier) error {
		st, err := lockPickingOrder(ctx, q, orderID, staleAfter)
		switch {
		case err != nil:
			return err
		case st.deleted:
			return model.ErrPickingOrderDeleted
		case st.hasUnknown:
			return model.ErrPickingOrderUnknown
		case st.status != model.PickingStatusNew && st.status != model.PickingStatusInProgress:
			return model.ErrPickingOrderClosed
		case st.status == model.PickingStatusInProgress && st.assignee != nil && *st.assignee == userID:
			return nil
		case st.status == model.PickingStatusInProgress && !st.stale:
			return model.ErrPickingOrderTaken
		}
		if _, err := q.Exec(ctx, `
			UPDATE picking_orders
			SET status = 'in_progress', assignee_id = $2::uuid, taken_at = now(), last_activity_at = now()
			WHERE id = $1::uuid`, orderID, userID); err != nil {
			return fmt.Errorf("взять заказ сборки: %w", err)
		}
		return nil
	})
}

// ReleaseOrder возвращает свой заказ в «новый» без исполнителя; собранное остаётся в коробах,
// следующий кладовщик продолжает. Заказ уже свободен — не ошибка (повтор).
func (r *PickingRepository) ReleaseOrder(ctx context.Context, orderID, userID string) error {
	return WithinTx(ctx, r.pool, func(q Querier) error {
		st, err := lockPickingOrder(ctx, q, orderID, 0)
		switch {
		case err != nil:
			return err
		case st.status == model.PickingStatusNew:
			return nil
		case st.status != model.PickingStatusInProgress:
			return model.ErrPickingOrderClosed
		case st.assignee == nil || *st.assignee != userID:
			return model.ErrPickingOrderTaken
		}
		if _, err := q.Exec(ctx, `
			UPDATE picking_orders SET status = 'new', assignee_id = NULL, taken_at = NULL
			WHERE id = $1::uuid`, orderID); err != nil {
			return fmt.Errorf("отказаться от заказа сборки: %w", err)
		}
		return nil
	})
}

// heldOrder — заказ в работе у этого кладовщика, под блокировкой; отмечает движение по нему
// (last_activity_at): действие по заказу продлевает его от зависания.
func heldOrder(ctx context.Context, q Querier, orderID, userID string) error {
	st, err := lockPickingOrder(ctx, q, orderID, 0)
	switch {
	case err != nil:
		return err
	case st.deleted:
		return model.ErrPickingOrderDeleted
	case st.status != model.PickingStatusInProgress || st.assignee == nil || *st.assignee != userID:
		return model.ErrPickingOrderNotYours
	}
	if _, err := q.Exec(ctx, `UPDATE picking_orders SET last_activity_at = now() WHERE id = $1::uuid`, orderID); err != nil {
		return fmt.Errorf("движение по заказу сборки: %w", err)
	}
	return nil
}

// AddBox заводит короб отгрузки заказа с id ярлыка, выданным ТСД, и возвращает его номер в заказе.
//
// Короб — грузовая единица без места: товар в него ляжет при «Завершить сборку» (P9-07). Повтор
// с тем же id по тому же заказу отдаёт уже выданный номер (ответ мог не дойти); id, занятый другим
// коробом, — отказ. Номер — следующий за последним коробом заказа; блокировка заказа держит
// его единственным.
func (r *PickingRepository) AddBox(ctx context.Context, orderID, userID, loadUnitID string) (int, error) {
	var seq int
	err := WithinTx(ctx, r.pool, func(q Querier) error {
		if err := heldOrder(ctx, q, orderID, userID); err != nil {
			return err
		}
		var owner *string
		var existing *int
		err := q.QueryRow(ctx, `
			SELECT pb.order_id::text, pb.seq FROM load_units lu
			LEFT JOIN picking_boxes pb ON pb.load_unit_id = lu.id
			WHERE lu.id = $1::uuid`, loadUnitID).Scan(&owner, &existing)
		switch {
		case err == nil && owner != nil && *owner == orderID:
			seq = *existing
			return nil
		case err == nil:
			return model.ErrPickingBoxForeign
		case !errors.Is(err, pgx.ErrNoRows):
			return fmt.Errorf("короб отгрузки: %w", err)
		}
		if _, err := q.Exec(ctx, `
			INSERT INTO load_units (id, kind, status) VALUES ($1::uuid, 'box', 'open')`, loadUnitID); err != nil {
			return fmt.Errorf("короб отгрузки: %w", err)
		}
		return q.QueryRow(ctx, `
			INSERT INTO picking_boxes (load_unit_id, order_id, seq, created_by)
			SELECT $1::uuid, $2::uuid, coalesce(max(seq), 0) + 1, $3::uuid
			FROM picking_boxes WHERE order_id = $2::uuid
			RETURNING seq`, loadUnitID, orderID, userID).Scan(&seq)
	})
	if err != nil {
		return 0, err
	}
	return seq, nil
}

// MarkShortage ставит или снимает у строки заказа отметку «не хватает».
//
// Отметка заводит пересчёт позиции (docs/picking.md, «Нехватка»): товар строки в ячейках, где WMS
// его числит, плюс ячейка реестра; основание — заказ сборки, задание — в общем пуле. Если по
// товару уже открыт пересчёт по нехватке, второй не заводится — отдаётся номер открытого. Всё —
// одной транзакцией с отметкой: отметка без пересчёта не остаётся. Снятие отметки пересчёт не
// отменяет — он уже в пуле, и посчитать товар не вредно.
func (r *PickingRepository) MarkShortage(ctx context.Context, orderID, lineID, userID string, shortage bool) (model.PickingShortageResult, error) {
	var res model.PickingShortageResult
	err := WithinTx(ctx, r.pool, func(q Querier) error {
		if err := heldOrder(ctx, q, orderID, userID); err != nil {
			return err
		}
		var goodID *string
		var cellID *string
		var warehouseID string
		err := q.QueryRow(ctx, `
			UPDATE picking_order_lines l SET shortage = $3
			FROM picking_orders o
			WHERE l.id = $2::uuid AND l.order_id = $1::uuid AND o.id = l.order_id AND l.removed_at IS NULL
			RETURNING l.good_id::text, l.cell_id::text, o.warehouse_id::text`,
			orderID, lineID, shortage).Scan(&goodID, &cellID, &warehouseID)
		if errors.Is(err, pgx.ErrNoRows) {
			return model.ErrPickingLineNotFound
		}
		if err != nil {
			return fmt.Errorf("отметка «не хватает»: %w", err)
		}
		if !shortage || goodID == nil {
			return nil
		}
		res, err = shortageStocktake(ctx, q, orderID, warehouseID, *goodID, cellID, userID)
		return err
	})
	return res, err
}

// shortageStocktake — открытый пересчёт по нехватке товара или новый.
func shortageStocktake(ctx context.Context, q Querier, orderID, warehouseID, goodID string, registryCellID *string, userID string) (model.PickingShortageResult, error) {
	var res model.PickingShortageResult
	if _, err := q.Exec(ctx, `SELECT pg_advisory_xact_lock($1, hashtext($2))`, pickingShortageLockKey, goodID); err != nil {
		return res, fmt.Errorf("блокировка пересчёта по нехватке: %w", err)
	}
	var number int64
	err := q.QueryRow(ctx, `
		SELECT st.number FROM stocktakes st
		JOIN stocktake_scope sc ON sc.stocktake_id = st.id
		WHERE st.picking_order_id IS NOT NULL AND st.status <> 'closed'
		  AND st.warehouse_id = $1::uuid AND sc.good_id = $2::uuid
		ORDER BY st.number LIMIT 1`, warehouseID, goodID).Scan(&number)
	switch {
	case err == nil:
		res.StocktakeNumber = &number
		return res, nil
	case !errors.Is(err, pgx.ErrNoRows):
		return res, fmt.Errorf("открытый пересчёт по нехватке: %w", err)
	}

	in := model.StocktakeCreateInput{
		WarehouseID: warehouseID, ScopeKind: model.StocktakeScopeGood, ObjectIDs: []string{goodID},
		CreatedBy: userID, PickingOrderID: orderID,
	}
	if registryCellID != nil {
		in.ExtraCellIDs = []string{*registryCellID}
	}
	// Считать негде — товара нет ни в одной ячейке, и ячейки реестра нет в WMS. Пустой пересчёт
	// ничего не посчитает, а отказ откатил бы и саму отметку: проверка — до заведения.
	var countable bool
	if err := q.QueryRow(ctx, `
		SELECT $3::uuid IS NOT NULL OR EXISTS (
			SELECT 1 FROM stock s JOIN cells c ON c.id = s.cell_id
			WHERE s.good_id = $2::uuid AND s.qty > 0 AND c.warehouse_id = $1::uuid
			  AND NOT c.is_default AND NOT c.is_shipping)`, warehouseID, goodID, registryCellID).Scan(&countable); err != nil {
		return res, fmt.Errorf("ячейки пересчёта по нехватке: %w", err)
	}
	if !countable {
		return res, nil
	}
	created, err := createStocktake(ctx, q, in)
	if err != nil {
		return res, err
	}
	res.StocktakeNumber, res.Created = &created.Number, true
	return res, nil
}
