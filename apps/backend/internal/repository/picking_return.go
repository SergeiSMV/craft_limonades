package repository

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
)

// KindPickingReturn - возврат товара из короба отгрузки в ячейку хранения по заданию «вернуть на
// места» (P9-07-1).
const KindPickingReturn = "picking_return"

// returnLine - строка заказа, по которой есть что вернуть на места.
//
// moved - сколько вернуть из коробов отгрузки: перенесённое сверх плана (убранная строка и
// удалённый заказ - план ноль). open - «в сборке» у источника, только у удалённого заказа: у
// живого лишний открытый пик возвращает сам кладовщик до «Завершить сборку».
type returnLine struct {
	id, name    string
	moved, open decimal.Decimal
}

func (l returnLine) left() decimal.Decimal { return l.moved.Add(l.open) }

// returnLines - что вернуть по строкам заказа; у отгруженного - ничего: товар уехал, правка после
// отгрузки только помечает заказ.
func returnLines(ctx context.Context, q Querier, orderID string) ([]returnLine, error) {
	rows, err := q.Query(ctx, `
		SELECT l.id::text, l.good_name,
		       CASE WHEN o.deleted_at IS NOT NULL OR l.removed_at IS NOT NULL THEN 0 ELSE l.plan_qty END,
		       coalesce(sum(p.qty) FILTER (WHERE p.state = 'moved'), 0)::text,
		       coalesce(sum(p.qty) FILTER (WHERE p.state = 'picking'), 0)::text,
		       o.deleted_at IS NOT NULL, o.status
		FROM picking_order_lines l
		JOIN picking_orders o ON o.id = l.order_id
		LEFT JOIN picking_picks p ON p.line_id = l.id
		WHERE l.order_id = $1::uuid
		GROUP BY l.id, o.id
		ORDER BY l.line_no`, orderID)
	if err != nil {
		return nil, fmt.Errorf("что вернуть по заказу: %w", err)
	}
	defer rows.Close()
	var out []returnLine
	for rows.Next() {
		var l returnLine
		var plan int
		var movedText, openText, status string
		var deleted bool
		if err := rows.Scan(&l.id, &l.name, &plan, &movedText, &openText, &deleted, &status); err != nil {
			return nil, fmt.Errorf("что вернуть по строке: %w", err)
		}
		if status == model.PickingStatusShipped {
			continue
		}
		moved, err := parseQty(movedText)
		if err != nil {
			return nil, err
		}
		open, err := parseQty(openText)
		if err != nil {
			return nil, err
		}
		l.moved = decimal.Max(moved.Sub(decimal.NewFromInt(int64(plan))), decimal.Zero)
		l.open = decimal.Zero
		if deleted {
			l.open = open
		}
		if l.left().IsPositive() {
			out = append(out, l)
		}
	}
	return out, rows.Err()
}

func returnTotal(lines []returnLine) decimal.Decimal {
	total := decimal.Zero
	for _, l := range lines {
		total = total.Add(l.left())
	}
	return total
}

// syncPickingReturnTask приводит задание «вернуть на места» заказа к остатку возврата (P9-07-1).
//
// Что: есть что вернуть и нет открытого задания - заводится; вернуть нечего, а задание открыто -
// закрывается. Зачем: остаток считается по пикам и плану, и его меняет не только возврат, но и
// повторная загрузка реестра (план снова вырос, заказ восстановлен). Как: по заданию уже
// возвращали или его взяли - оно «выполнено» (кем - исполнитель или последний вернувший); иначе
// задание удаляется: следов работы по нему нет. Вызывается в транзакции, где заказ заблокирован.
func syncPickingReturnTask(ctx context.Context, q Querier, orderID string) error {
	lines, err := returnLines(ctx, q, orderID)
	if err != nil {
		return err
	}
	left := returnTotal(lines).IsPositive()

	var taskID, status string
	var assignee, lastReturner *string
	var returned bool
	err = q.QueryRow(ctx, `
		SELECT t.id::text, t.status, t.assignee_id::text,
		       EXISTS (SELECT 1 FROM picking_returns r WHERE r.task_id = t.id),
		       (SELECT r.returned_by::text FROM picking_returns r WHERE r.task_id = t.id
		        ORDER BY r.returned_at DESC LIMIT 1)
		FROM warehouse_tasks t
		WHERE t.picking_order_id = $1::uuid AND t.status <> 'done'
		FOR UPDATE OF t`, orderID).Scan(&taskID, &status, &assignee, &returned, &lastReturner)
	noTask := errors.Is(err, pgx.ErrNoRows)
	if err != nil && !noTask {
		return fmt.Errorf("задание «вернуть на места»: %w", err)
	}

	switch {
	case noTask && left:
		if err := q.QueryRow(ctx, `
			INSERT INTO warehouse_tasks (kind, warehouse_id, picking_order_id)
			SELECT 'picking_return', warehouse_id, id FROM picking_orders WHERE id = $1::uuid
			RETURNING id::text`, orderID).Scan(&taskID); err != nil {
			return fmt.Errorf("завести задание «вернуть на места»: %w", err)
		}
		// Автора нет: задание заводит система по правке реестра.
		return addTaskEvent(ctx, q, taskID, model.TaskEventCreated, "", "", "")

	case !noTask && !left && (returned || status == model.TaskInProgress):
		by := deref(assignee)
		if by == "" {
			by = deref(lastReturner)
		}
		if _, err := q.Exec(ctx, `
			UPDATE warehouse_tasks
			SET status = 'done', assignee_id = NULL, completed_by = NULLIF($2, '')::uuid,
			    completed_at = now(), last_activity_at = now()
			WHERE id = $1::uuid`, taskID, by); err != nil {
			return fmt.Errorf("закрыть задание «вернуть на места»: %w", err)
		}
		return addTaskEvent(ctx, q, taskID, model.TaskEventCompleted, by, "", "")

	case !noTask && !left:
		if _, err := q.Exec(ctx, `DELETE FROM warehouse_tasks WHERE id = $1::uuid`, taskID); err != nil {
			return fmt.Errorf("снять задание «вернуть на места»: %w", err)
		}
	}
	return nil
}

// PickingReturnInput - возврат из очереди ТСД: сколько товара перенесённого пика вернуть в
// ячейку хранения. ReturnID выдаёт устройство; Marks - КИ маркируемого, по одной на единицу.
type PickingReturnInput struct {
	ReturnID string
	PickID   string
	CellID   string
	Qty      decimal.Decimal
	Marks    []string
	UserID   string
}

// pickingReturn применяет возврат в транзакции операции (P9-07-1).
//
// Что под блокировкой заказа, затем пика (тот же порядок, что у «Завершить сборку»):
//   - заказ не отгружен, пик перенесён в короб отгрузки (открытый возвращают picking_unpick);
//   - вернуть не больше, чем осталось вернуть по строке и чем есть в пике;
//   - ячейка - хранения склада заказа (не приёмка и не отгрузка), напольное хранение можно;
//   - маркируемый - только марками этого пика, по одной на единицу.
//
// Как: остаток - из `ОТГРУЗКИ` в ячейку той же строкой внутреннего склада, что у пика; из состава
// короба отгрузки - минус; марки - россыпью в ячейку. Пик уменьшается, весь вернули - «возвращён»:
// «перенесено» у пиков остаётся равным содержимому коробов, и отгрузка, портал и Excel считают
// верно без правок. Опустевший короб собранного заказа убирается, короба перенумеровываются, а
// отметки печати сбрасываются - ярлык «N из M» устарел. Исполнитель задания не проверяется:
// возврат уже сделан руками.
func pickingReturn(ctx context.Context, q Querier, in PickingReturnInput) error {
	var orderID string
	err := q.QueryRow(ctx, `SELECT order_id::text FROM picking_picks WHERE id = $1::uuid`, in.PickID).Scan(&orderID)
	if errors.Is(err, pgx.ErrNoRows) {
		return model.ErrPickingPickNotFound
	}
	if err != nil {
		return fmt.Errorf("пик: %w", err)
	}
	st, err := lockPickingOrder(ctx, q, orderID, 0)
	if err != nil {
		return err
	}
	if st.status == model.PickingStatusShipped {
		return model.ErrPickingOrderClosed
	}

	var lineID, state, boxID, goodID, batchID, iwh, warehouseID, qtyText string
	var pickMarks []string
	err = q.QueryRow(ctx, `
		SELECT p.line_id::text, p.state, p.box_id::text, p.good_id::text, p.batch_id::text,
		       p.internal_warehouse_id::text, o.warehouse_id::text, p.qty::text,
		       coalesce((SELECT array_agg(cis ORDER BY cis) FROM picking_pick_marks WHERE pick_id = p.id), '{}')
		FROM picking_picks p JOIN picking_orders o ON o.id = p.order_id
		WHERE p.id = $1::uuid
		FOR UPDATE OF p`, in.PickID).
		Scan(&lineID, &state, &boxID, &goodID, &batchID, &iwh, &warehouseID, &qtyText, &pickMarks)
	if err != nil {
		return fmt.Errorf("пик: %w", err)
	}
	switch state {
	case "picking":
		return model.ErrPickingReturnNotMoved
	case "returned":
		return model.ErrPickingReturnOverLeft
	}
	pickQty, err := parseQty(qtyText)
	if err != nil {
		return err
	}

	lines, err := returnLines(ctx, q, orderID)
	if err != nil {
		return err
	}
	lineLeft := decimal.Zero
	for _, l := range lines {
		if l.id == lineID {
			lineLeft = l.moved
		}
	}
	if in.Qty.GreaterThan(decimal.Min(lineLeft, pickQty)) {
		return model.ErrPickingReturnOverLeft
	}
	var taskID string
	err = q.QueryRow(ctx, `
		SELECT id::text FROM warehouse_tasks
		WHERE picking_order_id = $1::uuid AND status <> 'done' FOR UPDATE`, orderID).Scan(&taskID)
	if errors.Is(err, pgx.ErrNoRows) {
		return model.ErrPickingReturnOverLeft
	}
	if err != nil {
		return fmt.Errorf("задание «вернуть на места»: %w", err)
	}

	if err := guardReturnCell(ctx, q, warehouseID, in.CellID); err != nil {
		return err
	}
	if err := guardReturnMarks(pickMarks, in.Marks, in.Qty); err != nil {
		return err
	}

	shipping, err := (&CellRepository{}).EnsureShipping(ctx, q, warehouseID)
	if err != nil {
		return err
	}
	if err := transferStock(ctx, q,
		model.StockKey{CellID: shipping, GoodID: goodID, BatchID: batchID, InternalWarehouseID: iwh},
		model.StockKey{CellID: in.CellID, GoodID: goodID, BatchID: batchID, InternalWarehouseID: iwh},
		in.Qty); err != nil {
		return pickMoveErr(err)
	}
	tag, err := q.Exec(ctx, `
		UPDATE lu_content SET qty = qty - $4::numeric
		WHERE load_unit_id = $1::uuid AND good_id = $2::uuid AND batch_id = $3::uuid AND qty >= $4::numeric`,
		boxID, goodID, batchID, in.Qty.String())
	if err != nil {
		return fmt.Errorf("товар из короба отгрузки: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return model.ErrPickingStockShort
	}
	if len(in.Marks) > 0 {
		if _, err := q.Exec(ctx, `
			UPDATE cz_marks SET load_unit_id = NULL, cell_id = $2::uuid, internal_warehouse_id = $3::uuid,
			       updated_at = now()
			WHERE cis = ANY($1::text[])`, in.Marks, in.CellID, iwh); err != nil {
			return fmt.Errorf("марки в ячейку: %w", err)
		}
		// Целый короб ЧЗ, доживший до отгрузки нетронутым (CZ-07), вынутой из него маркой вскрыт.
		if err := openTouchedAggregates(ctx, q, in.Marks); err != nil {
			return err
		}
		if _, err := q.Exec(ctx, `
			DELETE FROM picking_pick_marks WHERE pick_id = $1::uuid AND cis = ANY($2::text[])`,
			in.PickID, in.Marks); err != nil {
			return fmt.Errorf("марки пика: %w", err)
		}
	}
	if in.Qty.Equal(pickQty) {
		_, err = q.Exec(ctx, `
			UPDATE picking_picks SET state = 'returned', returned_at = now() WHERE id = $1::uuid`, in.PickID)
	} else {
		_, err = q.Exec(ctx, `
			UPDATE picking_picks SET qty = qty - $2::numeric WHERE id = $1::uuid`, in.PickID, in.Qty.String())
	}
	if err != nil {
		return fmt.Errorf("вернуть пик: %w", err)
	}

	if _, err := q.Exec(ctx, `
		INSERT INTO picking_returns (id, order_id, task_id, pick_id, cell_id, qty, returned_by)
		VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, $5::uuid, $6::numeric, $7::uuid)`,
		in.ReturnID, orderID, taskID, in.PickID, in.CellID, in.Qty.String(), in.UserID); err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return model.ErrPickingReturnExists
		}
		return fmt.Errorf("возврат на место: %w", err)
	}
	if len(in.Marks) > 0 {
		if _, err := q.Exec(ctx, `
			INSERT INTO picking_return_marks (return_id, cis) SELECT $1::uuid, unnest($2::text[])`,
			in.ReturnID, in.Marks); err != nil {
			return fmt.Errorf("марки возврата: %w", err)
		}
	}
	if _, err := q.Exec(ctx, `
		UPDATE warehouse_tasks SET last_activity_at = now() WHERE id = $1::uuid`, taskID); err != nil {
		return fmt.Errorf("движение по заданию: %w", err)
	}
	qty := in.Qty
	if err := addPickingEvent(ctx, q, orderID, in.UserID,
		pickingEvent{kind: model.PickingEventReturned, qty: &qty}); err != nil {
		return err
	}

	// Короба в работе (дособор) кладовщик ещё наполняет - их перенумерует «Завершить сборку».
	if st.status == model.PickingStatusPicked || st.deleted {
		if err := settleBoxesAfterReturn(ctx, q, orderID); err != nil {
			return err
		}
	}
	return syncPickingReturnTask(ctx, q, orderID)
}

// guardReturnCell - ячейка возврата: хранения склада заказа, активная, не приёмка и не отгрузка.
func guardReturnCell(ctx context.Context, q Querier, warehouseID, cellID string) error {
	var ok bool
	err := q.QueryRow(ctx, `
		SELECT warehouse_id = $1::uuid AND is_active AND NOT is_default AND NOT is_shipping
		FROM cells WHERE id = $2::uuid`, warehouseID, cellID).Scan(&ok)
	if errors.Is(err, pgx.ErrNoRows) {
		return model.ErrUnknownReference
	}
	if err != nil {
		return fmt.Errorf("ячейка возврата: %w", err)
	}
	if !ok {
		return model.ErrPickingReturnCell
	}
	return nil
}

// guardReturnMarks - марки возврата: у маркируемого пика (марки есть) - его марки, по одной на
// единицу; у немаркируемого - ни одной.
func guardReturnMarks(pickMarks, marks []string, qty decimal.Decimal) error {
	if len(pickMarks) == 0 {
		if len(marks) > 0 {
			return model.ErrPickingReturnMarks
		}
		return nil
	}
	if !qty.Equal(decimal.NewFromInt(int64(len(uniqueStrings(marks))))) || len(uniqueStrings(marks)) != len(marks) {
		return model.ErrPickingReturnMarks
	}
	for _, m := range marks {
		if !slices.Contains(pickMarks, m) {
			return model.ErrPickingReturnMarks
		}
	}
	return nil
}

// settleBoxesAfterReturn убирает опустевшие короба собранного заказа и, если такие были,
// перенумеровывает живые и сбрасывает отметки печати: ярлык «N из M» устарел, новые ярлыки
// печатаются без права повтора.
func settleBoxesAfterReturn(ctx context.Context, q Querier, orderID string) error {
	dropped, err := dropEmptyBoxes(ctx, q, orderID)
	if err != nil || dropped == 0 {
		return err
	}
	if _, _, err := renumberLiveBoxes(ctx, q, orderID); err != nil {
		return err
	}
	if _, err := q.Exec(ctx, `
		UPDATE picking_boxes SET labels_printed = 0 WHERE order_id = $1::uuid`, orderID); err != nil {
		return fmt.Errorf("счётчик ярлыков: %w", err)
	}
	return nil
}

// PickingReturn применяет возврат под ключом идемпотентности.
func (r *OperationsRepository) PickingReturn(ctx context.Context, operationID string, in PickingReturnInput) (Applied, error) {
	applied, err := r.inTx(ctx, operationID, KindPickingReturn, func(q Querier) (json.RawMessage, error) {
		if err := pickingReturn(ctx, q, in); err != nil {
			return nil, err
		}
		return jsonResult(map[string]any{"return_id": in.ReturnID})
	})
	return applied, missingReference(err)
}

// ReturnView - что вернуть на места по заказу для экрана ТСД (P9-07-1).
// Нет такого заказа → ErrPickingOrderNotFound.
func (r *PickingRepository) ReturnView(ctx context.Context, orderID string) (model.PickingReturnView, error) {
	var v model.PickingReturnView
	err := r.pool.QueryRow(ctx, `
		SELECT o.id::text, o.number, o.invoice_number, o.order_number, o.client, o.status,
		       o.deleted_at IS NOT NULL,
		       (SELECT t.id::text FROM warehouse_tasks t
		        WHERE t.picking_order_id = o.id AND t.status <> 'done')
		FROM picking_orders o WHERE o.id = $1::uuid`, orderID).Scan(
		&v.OrderID, &v.Number, &v.InvoiceNumber, &v.OrderNumber, &v.Client, &v.Status, &v.Deleted, &v.TaskID)
	if errors.Is(err, pgx.ErrNoRows) {
		return v, model.ErrPickingOrderNotFound
	}
	if err != nil {
		return v, fmt.Errorf("заказ сборки: %w", err)
	}
	lines, err := returnLines(ctx, r.pool, orderID)
	if err != nil {
		return v, err
	}
	var movedLines, openLines []string
	for _, l := range lines {
		v.Lines = append(v.Lines, model.PickingReturnLine{LineID: l.id, GoodName: l.name, Left: l.left()})
		if l.moved.IsPositive() {
			movedLines = append(movedLines, l.id)
		}
		if l.open.IsPositive() {
			openLines = append(openLines, l.id)
		}
	}
	if len(lines) == 0 {
		return v, nil
	}
	rows, err := r.pool.Query(ctx, `
		SELECT p.id::text, p.line_id::text, p.state = 'moved', p.box_id::text, coalesce(b.seq, 0),
		       g.id::text, g.code, g.name, g.uom, g.cz_marked, bt.production_date, p.qty::text,
		       p.source_cell_id::text, c.address, p.source_load_unit_id::text,
		       coalesce((SELECT array_agg(cis ORDER BY cis) FROM picking_pick_marks WHERE pick_id = p.id), '{}')
		FROM picking_picks p
		JOIN goods g   ON g.id = p.good_id
		JOIN batches bt ON bt.id = p.batch_id
		JOIN cells c   ON c.id = p.source_cell_id
		LEFT JOIN picking_boxes b ON b.load_unit_id = p.box_id AND b.dropped_at IS NULL
		WHERE p.order_id = $1::uuid
		  AND ((p.state = 'moved' AND p.line_id = ANY($2::uuid[]))
		    OR (p.state = 'picking' AND p.line_id = ANY($3::uuid[])))
		ORDER BY p.state DESC, b.seq, g.name, bt.production_date, p.picked_at`,
		orderID, movedLines, openLines)
	if err != nil {
		return v, fmt.Errorf("пики возврата: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var p model.PickingReturnPick
		var qty string
		var prod time.Time
		if err := rows.Scan(&p.PickID, &p.LineID, &p.Moved, &p.BoxID, &p.BoxSeq, &p.GoodID, &p.GoodCode,
			&p.GoodName, &p.Uom, &p.Marked, &prod, &qty, &p.SourceCellID, &p.SourceCell,
			&p.SourceLoadUnitID, &p.Marks); err != nil {
			return v, fmt.Errorf("пик возврата: %w", err)
		}
		p.ProductionDate = prod
		if p.Qty, err = parseQty(qty); err != nil {
			return v, err
		}
		v.Picks = append(v.Picks, p)
	}
	return v, rows.Err()
}

// ReturnLeft - сколько штук осталось вернуть на места по заказам: id заказа → штук. Заказов без
// возврата в ответе нет.
func (r *PickingRepository) ReturnLeft(ctx context.Context, orderIDs []string) (map[string]decimal.Decimal, error) {
	return returnLeftOf(ctx, r.pool, orderIDs)
}

func returnLeftOf(ctx context.Context, q Querier, orderIDs []string) (map[string]decimal.Decimal, error) {
	out := map[string]decimal.Decimal{}
	for _, id := range uniqueStrings(orderIDs) {
		lines, err := returnLines(ctx, q, id)
		if err != nil {
			return nil, err
		}
		if total := returnTotal(lines); total.IsPositive() {
			out[id] = total
		}
	}
	return out, nil
}
