package repository

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"craftwms/internal/model"
	"craftwms/internal/picking"
)

// TaskOrder - заказ сборки со строками плана и взятым по каждой строке (P9-03).
// Нет такого заказа → ErrNotFound.
func (r *PickingRepository) TaskOrder(ctx context.Context, orderID string) (model.PickingTaskOrder, error) {
	var o model.PickingTaskOrder
	err := r.pool.QueryRow(ctx, `
		SELECT id::text, number, warehouse_id::text, registry_date, invoice_number, order_number,
		       direction, client, address, status, has_unknown, deleted_at IS NOT NULL, assignee_id::text
		FROM picking_orders WHERE id = $1`, orderID).Scan(
		&o.ID, &o.Number, &o.WarehouseID, &o.RegistryDate, &o.InvoiceNumber, &o.OrderNumber,
		&o.Direction, &o.Client, &o.Address, &o.Status, &o.HasUnknown, &o.Deleted, &o.AssigneeID)
	if errors.Is(err, pgx.ErrNoRows) {
		return o, model.ErrNotFound
	}
	if err != nil {
		return o, fmt.Errorf("заказ сборки: %w", err)
	}

	// Взятое по строке - пики в сборке и уже перенесённые в короб: возвращённые на место снова
	// в плане. Наименование - из 1С, единица и «маркируемый» - из справочника.
	rows, err := r.pool.Query(ctx, `
		SELECT l.id::text, l.line_no, l.good_id::text, l.good_code, l.good_name,
		       coalesce(g.uom, ''), coalesce(g.cz_marked, false),
		       l.batch_date, l.registry_cell, l.cell_id::text, coalesce(c.address, ''),
		       l.plan_qty, coalesce(p.qty, 0)::text, l.removed_at IS NOT NULL, l.shortage
		FROM picking_order_lines l
		LEFT JOIN goods g ON g.id = l.good_id
		LEFT JOIN cells c ON c.id = l.cell_id
		LEFT JOIN (
			SELECT line_id, sum(qty) AS qty FROM picking_picks
			WHERE order_id = $1 AND state IN ('picking', 'moved')
			GROUP BY line_id
		) p ON p.line_id = l.id
		WHERE l.order_id = $1
		ORDER BY l.line_no`, orderID)
	if err != nil {
		return o, fmt.Errorf("строки заказа сборки: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var l model.PickingTaskLine
		var taken string
		if err := rows.Scan(&l.ID, &l.LineNo, &l.GoodID, &l.GoodCode, &l.GoodName, &l.Uom, &l.CZMarked,
			&l.BatchDate, &l.RegistryCell, &l.CellID, &l.CellAddress,
			&l.PlanQty, &taken, &l.Removed, &l.Shortage); err != nil {
			return o, fmt.Errorf("строка заказа сборки: %w", err)
		}
		if l.Taken, err = parseQty(taken); err != nil {
			return o, err
		}
		o.Lines = append(o.Lines, l)
	}
	if err := rows.Err(); err != nil {
		return o, err
	}
	rows.Close()

	boxes, err := r.pool.Query(ctx, `
		SELECT load_unit_id::text, seq FROM picking_boxes WHERE order_id = $1 AND dropped_at IS NULL ORDER BY seq`, orderID)
	if err != nil {
		return o, fmt.Errorf("короба заказа сборки: %w", err)
	}
	defer boxes.Close()
	for boxes.Next() {
		var b model.PickingBox
		if err := boxes.Scan(&b.LoadUnitID, &b.Seq); err != nil {
			return o, fmt.Errorf("короб заказа сборки: %w", err)
		}
		o.Boxes = append(o.Boxes, b)
	}
	if err := boxes.Err(); err != nil {
		return o, err
	}
	boxes.Close()

	o.Picks, err = r.openPicks(ctx, orderID)
	return o, err
}

// openPicks - открытые пики заказа с марками (P9-06), в порядке пика.
func (r *PickingRepository) openPicks(ctx context.Context, orderID string) ([]model.PickingOpenPick, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT p.id::text, p.line_id::text, p.box_id::text, c.address,
		       coalesce(p.source_load_unit_id::text, ''), b.production_date, p.qty::text,
		       coalesce(array_agg(m.cis ORDER BY m.cis) FILTER (WHERE m.cis IS NOT NULL), '{}')
		FROM picking_picks p
		JOIN cells c ON c.id = p.source_cell_id
		JOIN batches b ON b.id = p.batch_id
		LEFT JOIN picking_pick_marks m ON m.pick_id = p.id
		WHERE p.order_id = $1 AND p.state = 'picking'
		GROUP BY p.id, c.address, b.production_date
		ORDER BY p.picked_at, p.id`, orderID)
	if err != nil {
		return nil, fmt.Errorf("пики заказа сборки: %w", err)
	}
	defer rows.Close()
	var out []model.PickingOpenPick
	for rows.Next() {
		var p model.PickingOpenPick
		var qty string
		if err := rows.Scan(&p.ID, &p.LineID, &p.BoxID, &p.CellAddress, &p.LoadUnitID,
			&p.BatchDate, &qty, &p.Marks); err != nil {
			return nil, fmt.Errorf("пик заказа сборки: %w", err)
		}
		if p.Qty, err = parseQty(qty); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// Sources - откуда можно собирать товары goodIDs на складе warehouseID (P9-03).
//
// Что: россыпь ячеек и короба хранения с доступным > 0. Где: активные ячейки склада, кроме
// служебных (`ПРИЁМКА`, `ОТГРУЗКА`), напольное хранение входит; только внутренние склады с
// галочкой «разрешить сборку». Доступное - остаток минус «в сборке» (открытые пики) того же
// источника: россыпь - пики без короба, короб - пики из этого короба. Россыпь - остаток склада
// в ячейке минус состав коробов того же склада в ней (правило looseStock).
//
// Короба отгрузки (picking_boxes) источником не бывают: их товар уже собран.
func (r *PickingRepository) Sources(ctx context.Context, warehouseID string, goodIDs []string) ([]picking.Source, error) {
	if len(goodIDs) == 0 {
		return nil, nil
	}
	rows, err := r.pool.Query(ctx, `
		WITH pickable AS (
			SELECT c.id, c.address, c.is_floor_storage FROM cells c
			WHERE c.warehouse_id = $1 AND c.is_active AND NOT c.is_default AND NOT c.is_shipping
		),
		boxes AS (
			SELECT lu.id, lu.cell_id, lu.internal_warehouse_id FROM load_units lu
			JOIN pickable pc ON pc.id = lu.cell_id
			WHERE NOT EXISTS (SELECT 1 FROM picking_boxes pb WHERE pb.load_unit_id = lu.id)
		),
		boxed AS (
			SELECT lu.cell_id, lu.internal_warehouse_id, c.good_id, c.batch_id, sum(c.qty) AS qty
			FROM lu_content c
			JOIN load_units lu ON lu.id = c.load_unit_id
			JOIN pickable pc ON pc.id = lu.cell_id
			WHERE c.good_id = ANY($2::uuid[])
			GROUP BY lu.cell_id, lu.internal_warehouse_id, c.good_id, c.batch_id
		),
		in_picking AS (
			SELECT source_cell_id, source_load_unit_id, internal_warehouse_id, good_id, batch_id, sum(qty) AS qty
			FROM picking_picks
			WHERE state = 'picking' AND good_id = ANY($2::uuid[])
			GROUP BY source_cell_id, source_load_unit_id, internal_warehouse_id, good_id, batch_id
		),
		sources AS (
			SELECT s.cell_id, NULL::uuid AS load_unit_id, s.internal_warehouse_id, s.good_id, s.batch_id,
			       s.qty - coalesce(bx.qty, 0) - coalesce(ip.qty, 0) AS available
			FROM stock s
			JOIN pickable pc ON pc.id = s.cell_id
			LEFT JOIN boxed bx ON bx.cell_id = s.cell_id AND bx.internal_warehouse_id = s.internal_warehouse_id
			                  AND bx.good_id = s.good_id AND bx.batch_id = s.batch_id
			LEFT JOIN in_picking ip ON ip.source_load_unit_id IS NULL AND ip.source_cell_id = s.cell_id
			                       AND ip.internal_warehouse_id = s.internal_warehouse_id
			                       AND ip.good_id = s.good_id AND ip.batch_id = s.batch_id
			WHERE s.good_id = ANY($2::uuid[])
			UNION ALL
			SELECT b.cell_id, b.id, b.internal_warehouse_id, c.good_id, c.batch_id,
			       c.qty - coalesce(ip.qty, 0)
			FROM lu_content c
			JOIN boxes b ON b.id = c.load_unit_id
			LEFT JOIN in_picking ip ON ip.source_load_unit_id = b.id
			                       AND ip.good_id = c.good_id AND ip.batch_id = c.batch_id
			WHERE c.good_id = ANY($2::uuid[])
		)
		SELECT src.cell_id::text, pc.address, pc.is_floor_storage, coalesce(src.load_unit_id::text, ''),
		       src.internal_warehouse_id::text, src.good_id::text, src.batch_id::text, bt.production_date,
		       src.available::text
		FROM sources src
		JOIN pickable pc ON pc.id = src.cell_id
		JOIN batches bt ON bt.id = src.batch_id
		JOIN internal_warehouses iw ON iw.id = src.internal_warehouse_id
		WHERE iw.allow_picking AND src.available > 0`, warehouseID, goodIDs)
	if err != nil {
		return nil, fmt.Errorf("источники сборки: %w", err)
	}
	defer rows.Close()
	var out []picking.Source
	for rows.Next() {
		var s picking.Source
		var batchDate time.Time
		var available string
		if err := rows.Scan(&s.CellID, &s.CellAddress, &s.IsFloorStorage, &s.LoadUnitID,
			&s.InternalWarehouseID, &s.GoodID, &s.BatchID, &batchDate, &available); err != nil {
			return nil, fmt.Errorf("источник сборки: %w", err)
		}
		s.BatchDate = batchDate
		if s.Available, err = parseQty(available); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}
