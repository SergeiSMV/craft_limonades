package repository

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
)

// pickingEvent — строка журнала событий заказа (P9-07). prevUser — чей заказ перехватили или
// сняли; boxes и qty — итог завершения и отгрузки.
type pickingEvent struct {
	kind     string
	prevUser *string
	boxes    *int
	qty      *decimal.Decimal
}

// addPickingEvent дописывает событие в журнал заказа в транзакции самого действия: событие без
// действия или действие без события не остаётся.
func addPickingEvent(ctx context.Context, q Querier, orderID, userID string, ev pickingEvent) error {
	var qty *string
	if ev.qty != nil {
		s := ev.qty.String()
		qty = &s
	}
	if _, err := q.Exec(ctx, `
		INSERT INTO picking_order_events (order_id, kind, user_id, prev_user_id, boxes, qty)
		VALUES ($1::uuid, $2, $3::uuid, $4::uuid, $5, $6::numeric)`,
		orderID, ev.kind, userID, ev.prevUser, ev.boxes, qty); err != nil {
		return fmt.Errorf("событие заказа сборки: %w", err)
	}
	return nil
}

// CompleteOrder — «Завершить сборку» (P9-07): остаток из ячеек в короба отгрузки, короба — в
// служебную ячейку `ОТГРУЗКА`, заказ — в «собран».
//
// Что под блокировкой заказа (только у своего исполнителя):
//   - строки: «в сборке» сверх плана — отказ (лишнее кладовщик возвращает пиком), взято меньше
//     плана без «не хватает» — отказ; ничего не взято — отказ, кроме заказа, где «не хватает»
//     по всем позициям: он собран частично без коробов. Перенесённое сверх плана после
//     правки реестра не мешает: его возвращает задание «вернуть на места» (P9-07-1), а
//     отгрузку до возврата не пустит ShipOrder;
//   - пустые короба убираются, живые перенумеровываются 1…M по прежнему порядку; если состав
//     коробов изменился с прошлого завершения (дособор), счётчик печати ярлыков сбрасывается —
//     старые ярлыки «N из M» неверны, новые печатаются без права повтора;
//   - каждый открытый пик: остаток — из ячейки-источника в `ОТГРУЗКУ` (той же строкой склада),
//     из короба хранения — минус его состав, в состав короба отгрузки — плюс; марки — в короб
//     отгрузки; пик — «перенесён». Пик сначала помечается перенесённым: «в сборке» вычитается из
//     доступного в коробе-источнике, и свой же пик иначе не дал бы взять товар;
//   - короба ставятся в `ОТГРУЗКУ` строкой журнала размещений; заказ — «собран», «частично» —
//     если по живой строке отмечено «не хватает» и взято меньше плана.
//
// Документ «Движение» не пишется: перенос внутри склада под заказ, его история — сами пики.
func (r *PickingRepository) CompleteOrder(ctx context.Context, orderID, userID string) (model.PickingShipment, error) {
	err := WithinTx(ctx, r.pool, func(q Querier) error {
		if err := heldOrder(ctx, q, orderID, userID); err != nil {
			return err
		}
		partial, err := checkCompleteLines(ctx, q, orderID)
		if err != nil {
			return err
		}
		boxes, err := renumberBoxes(ctx, q, orderID)
		if err != nil {
			return err
		}
		// Без коробов завершается только заказ, где по каждой позиции «не хватает»: он собран
		// частично ни с чем, и отгрузка закроет его без коробов. Иначе завершать нечего.
		if boxes == 0 && !partial {
			return model.ErrPickingNothingTaken
		}
		var warehouseID string
		if err := q.QueryRow(ctx, `SELECT warehouse_id::text FROM picking_orders WHERE id = $1::uuid`, orderID).
			Scan(&warehouseID); err != nil {
			return fmt.Errorf("склад заказа сборки: %w", err)
		}
		shipping, err := (&CellRepository{}).EnsureShipping(ctx, q, warehouseID)
		if err != nil {
			return err
		}
		if err := moveOpenPicks(ctx, q, orderID, shipping); err != nil {
			return err
		}
		if err := placeShippingBoxes(ctx, q, orderID, shipping, userID); err != nil {
			return err
		}
		var qty string
		if err := q.QueryRow(ctx, `
			UPDATE picking_orders
			SET status = 'picked', is_partial = $2, assignee_id = NULL, picked_by = $3::uuid,
			    picked_at = now(), last_activity_at = now()
			WHERE id = $1::uuid
			RETURNING (SELECT coalesce(sum(qty), 0) FROM picking_picks WHERE order_id = $1::uuid AND state = 'moved')::text`,
			orderID, partial, userID).Scan(&qty); err != nil {
			return fmt.Errorf("заказ собран: %w", err)
		}
		total, err := parseQty(qty)
		if err != nil {
			return err
		}
		return addPickingEvent(ctx, q, orderID, userID,
			pickingEvent{kind: model.PickingEventCompleted, boxes: &boxes, qty: &total})
	})
	if err != nil {
		return model.PickingShipment{}, err
	}
	return r.Shipment(ctx, orderID)
}

// checkCompleteLines сверяет взятое с планом по строкам; возвращает «собран частично».
//
// «В сборке» сверх плана — то, что ещё можно вернуть пиком: открытые пики сверх того, что план
// оставил после перенесённого. Убранная реестром строка — план ноль.
func checkCompleteLines(ctx context.Context, q Querier, orderID string) (bool, error) {
	rows, err := q.Query(ctx, `
		SELECT l.good_name, CASE WHEN l.removed_at IS NULL THEN l.plan_qty ELSE 0 END, l.shortage,
		       coalesce(sum(p.qty) FILTER (WHERE p.state = 'picking'), 0)::text,
		       coalesce(sum(p.qty) FILTER (WHERE p.state = 'moved'), 0)::text
		FROM picking_order_lines l
		LEFT JOIN picking_picks p ON p.line_id = l.id
		WHERE l.order_id = $1::uuid
		GROUP BY l.id
		ORDER BY l.line_no`, orderID)
	if err != nil {
		return false, fmt.Errorf("строки заказа сборки: %w", err)
	}
	defer rows.Close()
	var lerr model.PickingLinesError
	partial := false
	for rows.Next() {
		var name, openText, movedText string
		var plan int
		var shortage bool
		if err := rows.Scan(&name, &plan, &shortage, &openText, &movedText); err != nil {
			return false, fmt.Errorf("строка заказа сборки: %w", err)
		}
		open, err := parseQty(openText)
		if err != nil {
			return false, err
		}
		moved, err := parseQty(movedText)
		if err != nil {
			return false, err
		}
		planQty := decimal.NewFromInt(int64(plan))
		left := decimal.Max(planQty.Sub(moved), decimal.Zero)
		taken := open.Add(moved)
		switch {
		case open.GreaterThan(left):
			lerr.Excess = append(lerr.Excess, name)
		case taken.LessThan(planQty) && !shortage:
			lerr.Incomplete = append(lerr.Incomplete, name)
		case taken.LessThan(planQty):
			partial = true
		}
	}
	if err := rows.Err(); err != nil {
		return false, err
	}
	if len(lerr.Excess) > 0 || len(lerr.Incomplete) > 0 {
		return false, &lerr
	}
	return partial, nil
}

// renumberBoxes убирает пустые короба заказа и нумерует живые 1…M; возвращает M.
//
// Счётчик печати сбрасывается, если M или чей-то номер изменился с прошлого завершения: ярлык
// «N из M» устарел.
func renumberBoxes(ctx context.Context, q Querier, orderID string) (int, error) {
	if _, err := dropEmptyBoxes(ctx, q, orderID); err != nil {
		return 0, err
	}
	boxes, renumbered, err := renumberLiveBoxes(ctx, q, orderID)
	if err != nil {
		return 0, err
	}
	var prev *int
	err = q.QueryRow(ctx, `
		SELECT boxes FROM picking_order_events
		WHERE order_id = $1::uuid AND kind = 'completed' ORDER BY seq DESC LIMIT 1`, orderID).Scan(&prev)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return 0, fmt.Errorf("прошлое завершение сборки: %w", err)
	}
	if renumbered || (prev != nil && *prev != boxes) {
		if _, err := q.Exec(ctx, `
			UPDATE picking_boxes SET labels_printed = 0 WHERE order_id = $1::uuid`, orderID); err != nil {
			return 0, fmt.Errorf("счётчик ярлыков: %w", err)
		}
	}
	return boxes, nil
}

// dropEmptyBoxes убирает пустые короба заказа — без открытых и перенесённых пиков; возвращает,
// сколько убрано. Короб, стоявший в `ОТГРУЗКЕ` (опустел возвратом на места, P9-07-1), снимается
// с места: в ячейке отгрузки его больше нет.
func dropEmptyBoxes(ctx context.Context, q Querier, orderID string) (int, error) {
	rows, err := q.Query(ctx, `
		UPDATE picking_boxes b SET dropped_at = now()
		WHERE b.order_id = $1::uuid AND b.dropped_at IS NULL
		  AND NOT EXISTS (SELECT 1 FROM picking_picks p WHERE p.box_id = b.load_unit_id AND p.state <> 'returned')
		RETURNING b.load_unit_id::text`, orderID)
	if err != nil {
		return 0, fmt.Errorf("пустые короба отгрузки: %w", err)
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return 0, fmt.Errorf("пустые короба отгрузки: %w", err)
	}
	if len(ids) == 0 {
		return 0, nil
	}
	if _, err := q.Exec(ctx, `
		UPDATE load_units SET status = 'closed', cell_id = NULL, updated_at = now()
		WHERE id = ANY($1::uuid[]) AND cell_id IS NOT NULL`, ids); err != nil {
		return 0, fmt.Errorf("снять пустой короб с места: %w", err)
	}
	return len(ids), nil
}

// renumberLiveBoxes нумерует живые короба заказа 1…M по прежнему порядку; возвращает M и
// изменился ли чей-то номер. Номер переписывается в два шага (сначала вне диапазона):
// уникальность номера у живых коробов проверяется на каждой строке.
func renumberLiveBoxes(ctx context.Context, q Querier, orderID string) (int, bool, error) {
	var boxes int
	var renumbered bool
	if err := q.QueryRow(ctx, `
		WITH n AS (
			SELECT load_unit_id, seq, row_number() OVER (ORDER BY seq)::int AS new_seq
			FROM picking_boxes WHERE order_id = $1::uuid AND dropped_at IS NULL
		)
		SELECT count(*)::int, coalesce(bool_or(seq <> new_seq), false) FROM n`, orderID).
		Scan(&boxes, &renumbered); err != nil {
		return 0, false, fmt.Errorf("номера коробов отгрузки: %w", err)
	}
	if !renumbered {
		return boxes, false, nil
	}
	if _, err := q.Exec(ctx, `
		UPDATE picking_boxes SET seq = seq + 1000000
		WHERE order_id = $1::uuid AND dropped_at IS NULL`, orderID); err != nil {
		return 0, false, fmt.Errorf("номера коробов отгрузки: %w", err)
	}
	if _, err := q.Exec(ctx, `
		UPDATE picking_boxes b SET seq = n.new_seq
		FROM (SELECT load_unit_id, row_number() OVER (ORDER BY seq)::int AS new_seq
		      FROM picking_boxes WHERE order_id = $1::uuid AND dropped_at IS NULL) n
		WHERE b.load_unit_id = n.load_unit_id`, orderID); err != nil {
		return 0, false, fmt.Errorf("номера коробов отгрузки: %w", err)
	}
	return boxes, true, nil
}

// openPick — открытый пик под блокировкой: что, откуда, куда.
type openPick struct {
	id, box, good, batch, cell, iwh string
	loadUnit                        *string
	qty                             decimal.Decimal
	marks                           []string
}

// moveOpenPicks переносит открытые пики заказа в короба отгрузки (см. CompleteOrder).
func moveOpenPicks(ctx context.Context, q Querier, orderID, shippingCell string) error {
	rows, err := q.Query(ctx, `
		SELECT p.id::text, p.box_id::text, p.good_id::text, p.batch_id::text, p.source_cell_id::text,
		       p.internal_warehouse_id::text, p.source_load_unit_id::text, p.qty::text,
		       coalesce((SELECT array_agg(cis ORDER BY cis) FROM picking_pick_marks WHERE pick_id = p.id), '{}')
		FROM picking_picks p
		WHERE p.order_id = $1::uuid AND p.state = 'picking'
		ORDER BY p.picked_at, p.id
		FOR UPDATE OF p`, orderID)
	if err != nil {
		return fmt.Errorf("пики заказа сборки: %w", err)
	}
	var picks []openPick
	for rows.Next() {
		var p openPick
		var qty string
		if err := rows.Scan(&p.id, &p.box, &p.good, &p.batch, &p.cell, &p.iwh, &p.loadUnit, &qty, &p.marks); err != nil {
			rows.Close()
			return fmt.Errorf("пик заказа сборки: %w", err)
		}
		if p.qty, err = parseQty(qty); err != nil {
			rows.Close()
			return err
		}
		picks = append(picks, p)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	var marks []string
	for _, p := range picks {
		if _, err := q.Exec(ctx, `
			UPDATE picking_picks SET state = 'moved', moved_at = now() WHERE id = $1::uuid`, p.id); err != nil {
			return fmt.Errorf("перенести пик: %w", err)
		}
		if p.loadUnit != nil {
			if err := takeFromLoadUnit(ctx, q, *p.loadUnit, p.good, p.batch, p.qty); err != nil {
				return pickMoveErr(err)
			}
		}
		if err := transferStock(ctx, q,
			model.StockKey{CellID: p.cell, GoodID: p.good, BatchID: p.batch, InternalWarehouseID: p.iwh},
			model.StockKey{CellID: shippingCell, GoodID: p.good, BatchID: p.batch, InternalWarehouseID: p.iwh},
			p.qty); err != nil {
			return pickMoveErr(err)
		}
		if _, err := q.Exec(ctx, `
			INSERT INTO lu_content (load_unit_id, good_id, batch_id, qty)
			VALUES ($1::uuid, $2::uuid, $3::uuid, $4::numeric)
			ON CONFLICT (load_unit_id, good_id, batch_id) DO UPDATE SET qty = lu_content.qty + EXCLUDED.qty`,
			p.box, p.good, p.batch, p.qty.String()); err != nil {
			return fmt.Errorf("положить товар в короб отгрузки: %w", err)
		}
		if len(p.marks) > 0 {
			// Мимо moveMarks: та отказывает марке в открытом пике, а здесь пик и переносится.
			// Марки пик проверил при взятии и с тех пор держал: перемещение и проблема их не трогали.
			if _, err := q.Exec(ctx, `
				UPDATE cz_marks SET load_unit_id = $2::uuid, cell_id = NULL, internal_warehouse_id = NULL,
				       updated_at = now()
				WHERE cis = ANY($1::text[])`, p.marks, p.box); err != nil {
				return fmt.Errorf("марки в короб отгрузки: %w", err)
			}
			marks = append(marks, p.marks...)
		}
	}
	// Вскрытие — один раз после всех пиков (CZ-07): короб ЧЗ, целиком легший в один короб
	// отгрузки, остаётся целым и уходит в Excel своим кодом агрегации.
	if len(marks) > 0 {
		return openAggregatesShipped(ctx, q, marks)
	}
	return nil
}

// pickMoveErr — товара пика в источнике уже нет (пересчёт поправил остаток мимо «в сборке»):
// отказ с понятным текстом, а не «недостаточно остатка».
func pickMoveErr(err error) error {
	if errors.Is(err, ErrGoodsShort) || errors.Is(err, ErrInsufficientStock) {
		return model.ErrPickingStockShort
	}
	return err
}

// placeShippingBoxes ставит живые короба заказа в ячейку отгрузки.
func placeShippingBoxes(ctx context.Context, q Querier, orderID, shippingCell, userID string) error {
	rows, err := q.Query(ctx, `
		SELECT load_unit_id::text FROM picking_boxes
		WHERE order_id = $1::uuid AND dropped_at IS NULL ORDER BY seq`, orderID)
	if err != nil {
		return fmt.Errorf("короба отгрузки: %w", err)
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return fmt.Errorf("короба отгрузки: %w", err)
	}
	for _, id := range ids {
		if err := placeLoadUnit(ctx, q, model.PlaceLoadUnitInput{
			LoadUnitID: id, CellID: shippingCell, Source: model.PlacementPicking, UserID: userID,
		}); err != nil {
			return err
		}
	}
	return nil
}

// Shipment — собранный или отгруженный заказ с коробами «N из M» для ярлыков и отгрузки (P9-07).
// Нет такого заказа → ErrPickingOrderNotFound.
func (r *PickingRepository) Shipment(ctx context.Context, orderID string) (model.PickingShipment, error) {
	var s model.PickingShipment
	err := r.pool.QueryRow(ctx, `
		SELECT id::text, number, registry_date, invoice_number, order_number, direction, client, address,
		       status, is_partial, deleted_at IS NOT NULL
		FROM picking_orders WHERE id = $1::uuid`, orderID).Scan(
		&s.ID, &s.Number, &s.RegistryDate, &s.InvoiceNumber, &s.OrderNumber, &s.Direction, &s.Client,
		&s.Address, &s.Status, &s.IsPartial, &s.Deleted)
	if errors.Is(err, pgx.ErrNoRows) {
		return s, model.ErrPickingOrderNotFound
	}
	if err != nil {
		return s, fmt.Errorf("заказ сборки: %w", err)
	}
	rows, err := r.pool.Query(ctx, `
		SELECT b.load_unit_id::text, b.seq, b.labels_printed, b.shipped_at IS NOT NULL,
		       coalesce((SELECT sum(qty) FROM picking_picks p
		                 WHERE p.box_id = b.load_unit_id AND p.state <> 'returned'), 0)::text
		FROM picking_boxes b
		WHERE b.order_id = $1::uuid AND b.dropped_at IS NULL
		ORDER BY b.seq`, orderID)
	if err != nil {
		return s, fmt.Errorf("короба отгрузки: %w", err)
	}
	defer rows.Close()
	s.Qty = decimal.Zero
	for rows.Next() {
		var b model.PickingShipmentBox
		var qty string
		if err := rows.Scan(&b.LoadUnitID, &b.Seq, &b.LabelsPrinted, &b.Shipped, &qty); err != nil {
			return s, fmt.Errorf("короб отгрузки: %w", err)
		}
		if b.Qty, err = parseQty(qty); err != nil {
			return s, err
		}
		s.Qty = s.Qty.Add(b.Qty)
		s.Boxes = append(s.Boxes, b)
	}
	if err := rows.Err(); err != nil {
		return s, err
	}
	lines, err := returnLines(ctx, r.pool, orderID)
	if err != nil {
		return s, err
	}
	s.ReturnLeft = returnTotal(lines)
	return s, nil
}

// PrintLabels отмечает печать ярлыков коробов собранного заказа (P9-07) и возвращает заказ для
// печати. Ярлык, который уже печатали, — только с правом повторной печати (canReprint): иначе
// испорченный ярлык перепечатывает старший смены. Короб не этого заказа — ErrPickingShipBoxes.
func (r *PickingRepository) PrintLabels(ctx context.Context, orderID string, boxIDs []string, canReprint bool) (model.PickingShipment, error) {
	err := WithinTx(ctx, r.pool, func(q Querier) error {
		st, err := lockPickingOrder(ctx, q, orderID, 0)
		switch {
		case err != nil:
			return err
		case st.deleted:
			return model.ErrPickingOrderDeleted
		case st.status != model.PickingStatusPicked:
			return model.ErrPickingNotPicked
		}
		var found, printed int
		if err := q.QueryRow(ctx, `
			SELECT count(*)::int, count(*) FILTER (WHERE labels_printed > 0)::int FROM picking_boxes
			WHERE order_id = $1::uuid AND dropped_at IS NULL AND load_unit_id = ANY($2::uuid[])`,
			orderID, boxIDs).Scan(&found, &printed); err != nil {
			return fmt.Errorf("короба для ярлыков: %w", err)
		}
		switch {
		case len(boxIDs) == 0 || found != len(uniqueStrings(boxIDs)):
			return model.ErrPickingShipBoxes
		case printed > 0 && !canReprint:
			return model.ErrPickingReprintDenied
		}
		if _, err := q.Exec(ctx, `
			UPDATE picking_boxes SET labels_printed = labels_printed + 1
			WHERE order_id = $1::uuid AND load_unit_id = ANY($2::uuid[])`, orderID, boxIDs); err != nil {
			return fmt.Errorf("счётчик ярлыков: %w", err)
		}
		return nil
	})
	if err != nil {
		return model.PickingShipment{}, err
	}
	return r.Shipment(ctx, orderID)
}

// ShipOrder — «Отгрузить» (P9-07): отсканированы ярлыки всех коробов собранного заказа — короба
// и их товар уходят со склада.
//
// Набор boxIDs обязан совпасть с живыми коробами заказа: не все или чужой — ErrPickingShipBoxes.
// Есть что вернуть на места после правки реестра — ErrPickingReturnPending (P9-07-1).
// Остаток уходит из `ОТГРУЗКИ` той же строкой склада, что лёг туда при завершении (по
// перенесённым пикам); состав коробов обнуляется, короба — shipped без места, марки — shipped.
// Отгруженный повторно — не ошибка (ответ мог не дойти).
func (r *PickingRepository) ShipOrder(ctx context.Context, orderID, userID string, boxIDs []string) (model.PickingShipment, error) {
	err := WithinTx(ctx, r.pool, func(q Querier) error {
		st, err := lockPickingOrder(ctx, q, orderID, 0)
		switch {
		case err != nil:
			return err
		case st.status == model.PickingStatusShipped:
			return nil
		case st.deleted:
			return model.ErrPickingOrderDeleted
		case st.status != model.PickingStatusPicked:
			return model.ErrPickingNotPicked
		}
		// Лишнее сверх нового плана уехало бы клиенту и списалось со склада (P9-07-1).
		lines, err := returnLines(ctx, q, orderID)
		if err != nil {
			return err
		}
		if returnTotal(lines).IsPositive() {
			return model.ErrPickingReturnPending
		}
		var total, matched int
		if err := q.QueryRow(ctx, `
			SELECT count(*)::int, count(*) FILTER (WHERE load_unit_id = ANY($2::uuid[]))::int
			FROM picking_boxes WHERE order_id = $1::uuid AND dropped_at IS NULL`,
			orderID, boxIDs).Scan(&total, &matched); err != nil {
			return fmt.Errorf("короба отгрузки: %w", err)
		}
		// Коробов нет (по всем позициям «не хватает») - отгрузка пустым набором закрывает заказ.
		if matched != total || len(uniqueStrings(boxIDs)) != total {
			return model.ErrPickingShipBoxes
		}

		var warehouseID string
		if err := q.QueryRow(ctx, `SELECT warehouse_id::text FROM picking_orders WHERE id = $1::uuid`, orderID).
			Scan(&warehouseID); err != nil {
			return fmt.Errorf("склад заказа сборки: %w", err)
		}
		shipping, err := (&CellRepository{}).EnsureShipping(ctx, q, warehouseID)
		if err != nil {
			return err
		}
		rows, err := q.Query(ctx, `
			SELECT good_id::text, batch_id::text, internal_warehouse_id::text, sum(qty)::text
			FROM picking_picks WHERE order_id = $1::uuid AND state = 'moved'
			GROUP BY good_id, batch_id, internal_warehouse_id`, orderID)
		if err != nil {
			return fmt.Errorf("товар отгрузки: %w", err)
		}
		type facet struct{ good, batch, iwh, qty string }
		facets, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (facet, error) {
			var f facet
			err := row.Scan(&f.good, &f.batch, &f.iwh, &f.qty)
			return f, err
		})
		if err != nil {
			return fmt.Errorf("товар отгрузки: %w", err)
		}
		total2 := decimal.Zero
		for _, f := range facets {
			qty, err := parseQty(f.qty)
			if err != nil {
				return err
			}
			total2 = total2.Add(qty)
			if err := removeStock(ctx, q,
				model.StockKey{CellID: shipping, GoodID: f.good, BatchID: f.batch, InternalWarehouseID: f.iwh},
				qty); err != nil {
				return fmt.Errorf("остаток в ячейке отгрузки: %w", err)
			}
		}
		if _, err := q.Exec(ctx, `
			UPDATE lu_content SET qty = 0
			WHERE load_unit_id IN (SELECT load_unit_id FROM picking_boxes WHERE order_id = $1::uuid)`, orderID); err != nil {
			return fmt.Errorf("состав коробов отгрузки: %w", err)
		}
		if _, err := q.Exec(ctx, `
			UPDATE cz_marks SET status = 'shipped', load_unit_id = NULL, cell_id = NULL,
			       internal_warehouse_id = NULL, updated_at = now()
			WHERE status = 'in_stock'
			  AND load_unit_id IN (SELECT load_unit_id FROM picking_boxes WHERE order_id = $1::uuid)`, orderID); err != nil {
			return fmt.Errorf("марки отгрузки: %w", err)
		}
		if _, err := q.Exec(ctx, `
			UPDATE load_units SET status = 'shipped', cell_id = NULL
			WHERE id IN (SELECT load_unit_id FROM picking_boxes WHERE order_id = $1::uuid AND dropped_at IS NULL)`,
			orderID); err != nil {
			return fmt.Errorf("короба отгружены: %w", err)
		}
		if _, err := q.Exec(ctx, `
			UPDATE picking_boxes SET shipped_by = $2::uuid, shipped_at = now()
			WHERE order_id = $1::uuid AND dropped_at IS NULL`, orderID, userID); err != nil {
			return fmt.Errorf("короба отгружены: %w", err)
		}
		if _, err := q.Exec(ctx, `
			UPDATE picking_orders SET status = 'shipped', shipped_by = $2::uuid, shipped_at = now()
			WHERE id = $1::uuid`, orderID, userID); err != nil {
			return fmt.Errorf("заказ отгружен: %w", err)
		}
		return addPickingEvent(ctx, q, orderID, userID,
			pickingEvent{kind: model.PickingEventShipped, boxes: &total, qty: &total2})
	})
	if err != nil {
		return model.PickingShipment{}, err
	}
	return r.Shipment(ctx, orderID)
}

// uniqueStrings — различные значения среза: повторный скан одного ярлыка не считается вторым коробом.
func uniqueStrings(in []string) []string {
	seen := make(map[string]bool, len(in))
	out := make([]string, 0, len(in))
	for _, s := range in {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}
