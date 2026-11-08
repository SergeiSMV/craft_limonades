package repository

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
)

// Типы операций сборки в очереди ТСД (P9-05).
const (
	// KindPickingPick — пик: товар взят из ячейки или короба хранения в короб отгрузки.
	KindPickingPick = "picking_pick"
	// KindPickingUnpick — взятое возвращено на место до «Завершить сборку».
	KindPickingUnpick = "picking_unpick"
)

// ErrShippingCell — ячейка отгрузки в движении (P9-05): в ней числятся короба собранных заказов,
// и уходят они оттуда только отгрузкой.
var ErrShippingCell = errors.New("ячейка отгрузки - служебная: короба собранных заказов уходят из неё только отгрузкой")

// PickingPickInput — пик из очереди ТСД.
//
// Источник — ровно один: россыпь ячейки (SourceCellID, склад — InternalWarehouseID, пусто — по
// умолчанию) или короб хранения (SourceLoadUnitID: ячейку и склад даёт короб). PickID выдаёт
// устройство: по нему же пик возвращают. Marks — КИ маркируемого товара, по одной на единицу.
type PickingPickInput struct {
	PickID              string
	OrderID             string
	LineID              string
	BoxID               string
	SourceCellID        string
	SourceLoadUnitID    string
	InternalWarehouseID string
	ProductionDate      string
	Qty                 decimal.Decimal
	Marks               []string
	PickedBy            string
}

// pickingPick применяет пик в транзакции операции.
//
// Что: строка picking_picks в состоянии «в сборке» и её марки; остаток ячейки и место марок не
// меняются — товар уходит из ячейки при «Завершить сборку» (P9-07), «в сборке» уменьшает
// доступное (looseQty, takeFromLoadUnit).
//
// Проверки — под блокировками, чтобы два пика одного остатка не прошли оба:
//   - заказ блокируется: не удалён, не собран и не отгружен; исполнитель не проверяется — пик уже
//     сделан руками, и отказ из-за смены исполнителя оставил бы товар в коробе, а в учёте в ячейке;
//   - строка заказа жива, взятое по ней с этим пиком — не больше плана;
//   - короб отгрузки — этого заказа;
//   - источник — ячейка хранения склада заказа (не приёмка и не отгрузка) на складе с
//     «разрешить сборку», и доступного (остаток минус «в сборке») хватает;
//   - марки маркируемого товара — на складе, в источнике, этой партии, не в другом пике.
func pickingPick(ctx context.Context, q Querier, in PickingPickInput) error {
	var warehouseID, status string
	var deleted bool
	err := q.QueryRow(ctx, `
		SELECT warehouse_id::text, status, deleted_at IS NOT NULL
		FROM picking_orders WHERE id = $1::uuid FOR UPDATE`, in.OrderID).Scan(&warehouseID, &status, &deleted)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return model.ErrPickingOrderNotFound
	case err != nil:
		return fmt.Errorf("заказ сборки: %w", err)
	case deleted:
		return model.ErrPickingOrderDeleted
	case status != model.PickingStatusNew && status != model.PickingStatusInProgress:
		return model.ErrPickingOrderClosed
	}

	var goodID *string
	var plan int
	var taken decimal.Decimal
	var takenText string
	err = q.QueryRow(ctx, `
		SELECT l.good_id::text, l.plan_qty,
		       COALESCE((SELECT sum(qty) FROM picking_picks p
		                 WHERE p.line_id = l.id AND p.state IN ('picking', 'moved')), 0)::text
		FROM picking_order_lines l
		WHERE l.id = $1::uuid AND l.order_id = $2::uuid AND l.removed_at IS NULL`,
		in.LineID, in.OrderID).Scan(&goodID, &plan, &takenText)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && goodID == nil) {
		return model.ErrPickingLineNotFound
	}
	if err != nil {
		return fmt.Errorf("строка заказа сборки: %w", err)
	}
	if taken, err = parseQty(takenText); err != nil {
		return err
	}
	if taken.Add(in.Qty).GreaterThan(decimal.NewFromInt(int64(plan))) {
		return model.ErrPickingOverPlan
	}

	var boxOrder string
	// Пустой короб, убранный при «Завершить сборку» (P9-07), — уже не короб заказа.
	err = q.QueryRow(ctx, `
		SELECT order_id::text FROM picking_boxes WHERE load_unit_id = $1::uuid AND dropped_at IS NULL`,
		in.BoxID).Scan(&boxOrder)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && boxOrder != in.OrderID) {
		return model.ErrPickingBoxNotInOrder
	}
	if err != nil {
		return fmt.Errorf("короб отгрузки: %w", err)
	}

	batchID, err := existingBatch(ctx, q, *goodID, in.ProductionDate)
	if err != nil {
		return err
	}

	cell, iwh := in.SourceCellID, in.InternalWarehouseID
	if in.SourceLoadUnitID != "" {
		var isShippingBox bool
		if err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM picking_boxes WHERE load_unit_id = $1::uuid)`,
			in.SourceLoadUnitID).Scan(&isShippingBox); err != nil {
			return fmt.Errorf("короб-источник: %w", err)
		}
		if isShippingBox {
			return model.ErrPickingSourceIsBox
		}
		boxes, err := lockPlacedLoadUnits(ctx, q, in.SourceLoadUnitID)
		if err != nil {
			return err
		}
		box := boxes[in.SourceLoadUnitID]
		cell, iwh = box.cell, box.iwh
	} else if iwh == "" {
		if iwh, err = defaultInternalWarehouse(ctx, q); err != nil {
			return err
		}
	}
	if err := guardPickingSource(ctx, q, warehouseID, cell, iwh); err != nil {
		return err
	}

	// Доступное — под блокировкой строки, из которой товар числится: россыпь — строка остатка
	// (looseQty), короб — строка состава.
	if in.SourceLoadUnitID != "" {
		var available decimal.Decimal
		var text string
		err := q.QueryRow(ctx, `
			WITH locked AS (
				SELECT qty FROM lu_content
				WHERE load_unit_id = $1::uuid AND good_id = $2::uuid AND batch_id = $3::uuid
				FOR UPDATE
			)
			SELECT (COALESCE((SELECT qty FROM locked), 0)
			      - COALESCE((SELECT sum(p.qty) FROM picking_picks p
			                  WHERE p.state = 'picking' AND p.source_load_unit_id = $1::uuid
			                    AND p.good_id = $2::uuid AND p.batch_id = $3::uuid), 0))::text`,
			in.SourceLoadUnitID, *goodID, batchID).Scan(&text)
		if err != nil {
			return fmt.Errorf("доступное в коробе: %w", err)
		}
		if available, err = parseQty(text); err != nil {
			return err
		}
		if available.LessThan(in.Qty) {
			return model.ErrPickingStockShort
		}
	} else {
		loose, err := looseQty(ctx, q, cell, *goodID, batchID, iwh)
		if err != nil {
			return err
		}
		if loose.LessThan(in.Qty) {
			return model.ErrPickingStockShort
		}
	}

	if err := pickMarks(ctx, q, *goodID, batchID, in.Marks, in.Qty, placeOf(in.SourceLoadUnitID, cell, iwh)); err != nil {
		return err
	}

	if _, err := q.Exec(ctx, `
		INSERT INTO picking_picks (id, order_id, line_id, box_id, good_id, batch_id, source_cell_id,
		                           source_load_unit_id, internal_warehouse_id, qty, picked_by)
		VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, $5::uuid, $6::uuid, $7::uuid,
		        NULLIF($8, '')::uuid, $9::uuid, $10::numeric, $11::uuid)`,
		in.PickID, in.OrderID, in.LineID, in.BoxID, *goodID, batchID, cell,
		in.SourceLoadUnitID, iwh, in.Qty.String(), in.PickedBy); err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return model.ErrPickingPickExists
		}
		return fmt.Errorf("пик: %w", err)
	}
	if len(in.Marks) > 0 {
		if _, err := q.Exec(ctx, `
			INSERT INTO picking_pick_marks (pick_id, cis) SELECT $1::uuid, unnest($2::text[])`,
			in.PickID, in.Marks); err != nil {
			return fmt.Errorf("марки пика: %w", err)
		}
	}
	if _, err := q.Exec(ctx, `UPDATE picking_orders SET last_activity_at = now() WHERE id = $1::uuid`, in.OrderID); err != nil {
		return fmt.Errorf("движение по заказу сборки: %w", err)
	}
	return nil
}

// guardPickingSource — источник сборки: ячейка хранения склада заказа (активная, не приёмка и не
// отгрузка; напольное хранение можно) на внутреннем складе с галочкой «разрешить сборку».
func guardPickingSource(ctx context.Context, q Querier, warehouseID, cellID, iwh string) error {
	var ok bool
	err := q.QueryRow(ctx, `
		SELECT c.warehouse_id = $1::uuid AND c.is_active AND NOT c.is_default AND NOT c.is_shipping
		       AND (SELECT allow_picking FROM internal_warehouses WHERE id = $3::uuid)
		FROM cells c WHERE c.id = $2::uuid`, warehouseID, cellID, iwh).Scan(&ok)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrUnknownReference
	}
	if err != nil {
		return fmt.Errorf("источник сборки: %w", err)
	}
	if !ok {
		return model.ErrPickingSourceDenied
	}
	return nil
}

// pickMarks проверяет марки пика: правило moveMarks без переноса — марка остаётся на месте до
// «Завершить сборку», но в другой пик уже не берётся.
func pickMarks(ctx context.Context, q Querier, goodID, batchID string, marks []string, qty decimal.Decimal, from markPlace) error {
	if len(marks) == 0 {
		var marked bool
		if err := q.QueryRow(ctx, `SELECT cz_marked FROM goods WHERE id = $1::uuid`, goodID).Scan(&marked); err != nil {
			return fmt.Errorf("признак маркировки товара: %w", err)
		}
		if marked {
			return model.ErrCZMarksRequired
		}
		return nil
	}
	if !qty.Equal(decimal.NewFromInt(int64(len(marks)))) {
		return model.ErrCZMarksQtyMismatch
	}
	locked, err := lockMarks(ctx, q, marks)
	if err != nil {
		return err
	}
	for _, m := range locked {
		if m.good != goodID || m.batch != batchID {
			return model.ErrCZMarkBatchMismatch
		}
		if m.status != model.CZMarkInStock || m.place != from {
			return model.ErrCZMarkNotAtSource
		}
	}
	return guardMarksNotInPicking(ctx, q, marks)
}

// guardMarksNotInPicking — ни одна марка не в открытом пике (P9-05). Марка в сборке физически в
// коробе отгрузки: её не перемещают, не помечают проблемой и не берут вторым пиком.
func guardMarksNotInPicking(ctx context.Context, q Querier, marks []string) error {
	var busy bool
	if err := q.QueryRow(ctx, `
		SELECT EXISTS (SELECT 1 FROM picking_pick_marks pm JOIN picking_picks p ON p.id = pm.pick_id
		               WHERE pm.cis = ANY($1::text[]) AND p.state = 'picking')`, marks).Scan(&busy); err != nil {
		return fmt.Errorf("марки в сборке: %w", err)
	}
	if busy {
		return model.ErrPickingMarkInPicking
	}
	return nil
}

// guardLoadUnitNotInPicking — из короба хранения нет открытых пиков (P9-05).
func guardLoadUnitNotInPicking(ctx context.Context, q Querier, loadUnitID string) error {
	var busy bool
	if err := q.QueryRow(ctx, `
		SELECT EXISTS (SELECT 1 FROM picking_picks WHERE source_load_unit_id = $1::uuid AND state = 'picking')`,
		loadUnitID).Scan(&busy); err != nil {
		return fmt.Errorf("короб в сборке: %w", err)
	}
	if busy {
		return model.ErrPickingLoadUnitBusy
	}
	return nil
}

// guardNotShippingCell отклоняет ячейку отгрузки в движении (P9-05): её короба уходят только
// отгрузкой, а положить в неё товар мимо «Завершить сборку» значило бы потерять его из учёта
// хранения.
func guardNotShippingCell(ctx context.Context, q Querier, cellID string) error {
	var shipping bool
	err := q.QueryRow(ctx, `SELECT is_shipping FROM cells WHERE id = $1::uuid`, cellID).Scan(&shipping)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrUnknownReference
	}
	if err != nil {
		return fmt.Errorf("проверить ячейку отгрузки: %w", err)
	}
	if shipping {
		return ErrShippingCell
	}
	return nil
}

// pickingUnpick возвращает пик на место до «Завершить сборку»: «в сборке» уменьшается, остаток
// и марки и так не двигались. Перенесённый в короб отгрузки — отказ: его возвращает задание
// «вернуть на места» (P9-07). Уже возвращённый — не ошибка.
func pickingUnpick(ctx context.Context, q Querier, pickID string) error {
	var state, orderID string
	err := q.QueryRow(ctx, `SELECT state, order_id::text FROM picking_picks WHERE id = $1::uuid FOR UPDATE`, pickID).
		Scan(&state, &orderID)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return model.ErrPickingPickNotFound
	case err != nil:
		return fmt.Errorf("пик: %w", err)
	case state == "returned":
		return nil
	case state == "moved":
		return model.ErrPickingPickMoved
	}
	if _, err := q.Exec(ctx, `
		UPDATE picking_picks SET state = 'returned', returned_at = now() WHERE id = $1::uuid`, pickID); err != nil {
		return fmt.Errorf("вернуть пик: %w", err)
	}
	if _, err := q.Exec(ctx, `UPDATE picking_orders SET last_activity_at = now() WHERE id = $1::uuid`, orderID); err != nil {
		return fmt.Errorf("движение по заказу сборки: %w", err)
	}
	return nil
}

// PickingPick применяет пик под ключом идемпотентности: повтор операции второй раз не пикает.
func (r *OperationsRepository) PickingPick(ctx context.Context, operationID string, in PickingPickInput) (Applied, error) {
	applied, err := r.inTx(ctx, operationID, KindPickingPick, func(q Querier) (json.RawMessage, error) {
		if err := pickingPick(ctx, q, in); err != nil {
			return nil, err
		}
		return jsonResult(map[string]any{"pick_id": in.PickID})
	})
	return applied, missingReference(err)
}

// PickingUnpick возвращает пик под ключом идемпотентности.
func (r *OperationsRepository) PickingUnpick(ctx context.Context, operationID, pickID string) (Applied, error) {
	applied, err := r.inTx(ctx, operationID, KindPickingUnpick, func(q Querier) (json.RawMessage, error) {
		return nil, pickingUnpick(ctx, q, pickID)
	})
	return applied, missingReference(err)
}
