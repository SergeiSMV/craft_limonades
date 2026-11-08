package repository

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/model"
)

// pickingLoadLockKey — пространство advisory-блокировок загрузки реестра (P8-02); второй ключ —
// склад и дата. Две загрузки одной даты не сверяются с одним и тем же прошлым состоянием.
const pickingLoadLockKey = 1040

// PickingRepository — документы сборки по реестру 1С (P8-02): сверка загрузки с прошлой,
// остаток для предпросмотра, запись загрузки.
type PickingRepository struct {
	pool *pgxpool.Pool
}

// NewPickingRepository создаёт репозиторий сборки.
func NewPickingRepository(pool *pgxpool.Pool) *PickingRepository {
	return &PickingRepository{pool: pool}
}

// ExistingOrders — заказы склада на дату накладной со строками, и удалённые, и убранные строки.
func (r *PickingRepository) ExistingOrders(ctx context.Context, warehouseID string, date time.Time) ([]model.PickingExistingOrder, error) {
	return existingPickingOrders(ctx, r.pool, warehouseID, date)
}

func existingPickingOrders(ctx context.Context, q Querier, warehouseID string, date time.Time) ([]model.PickingExistingOrder, error) {
	rows, err := q.Query(ctx, `
		SELECT o.id::text, o.number, o.order_number, o.status, o.deleted_at IS NOT NULL, o.picked_by::text,
		       l.id::text, l.good_code, l.good_name, l.batch_date, l.plan_qty, l.removed_at IS NOT NULL
		FROM picking_orders o
		LEFT JOIN picking_order_lines l ON l.order_id = o.id
		WHERE o.warehouse_id = $1 AND o.registry_date = $2
		ORDER BY o.number, l.line_no`, warehouseID, date)
	if err != nil {
		return nil, fmt.Errorf("заказы сборки на дату: %w", err)
	}
	defer rows.Close()
	var out []model.PickingExistingOrder
	for rows.Next() {
		var o model.PickingExistingOrder
		var lineID, code, name *string
		var batch *time.Time
		var qty *int
		var removed *bool
		if err := rows.Scan(&o.ID, &o.Number, &o.OrderNumber, &o.Status, &o.Deleted, &o.PickedBy,
			&lineID, &code, &name, &batch, &qty, &removed); err != nil {
			return nil, fmt.Errorf("строка заказа сборки: %w", err)
		}
		if len(out) == 0 || out[len(out)-1].ID != o.ID {
			out = append(out, o)
		}
		if lineID != nil {
			last := &out[len(out)-1]
			last.Lines = append(last.Lines, model.PickingExistingLine{
				ID: *lineID, GoodCode: *code, GoodName: *name, BatchDate: batch, PlanQty: *qty, Removed: *removed,
			})
		}
	}
	return out, rows.Err()
}

// CellAddresses — активные ячейки хранения склада: адрес → id. Служебные (приёмка, отгрузка)
// не входят: в них реестр не указывает.
func (r *PickingRepository) CellAddresses(ctx context.Context, warehouseID string) (map[string]string, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT id::text, address FROM cells
		WHERE warehouse_id = $1 AND is_active AND NOT is_default AND NOT is_shipping`, warehouseID)
	if err != nil {
		return nil, fmt.Errorf("ячейки склада: %w", err)
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var id, address string
		if err := rows.Scan(&id, &address); err != nil {
			return nil, fmt.Errorf("ячейка склада: %w", err)
		}
		out[address] = id
	}
	return out, rows.Err()
}

// Stock — остаток товаров по партиям, из которого можно собирать: внутренние склады с галочкой
// «разрешить сборку», ячейки хранения склада (без приёмки и отгрузки). Товар «в сборке» ещё
// числится в ячейке и здесь не вычитается: план собирающихся заказов сравнивается с ним целиком.
func (r *PickingRepository) Stock(ctx context.Context, warehouseID string, goodIDs []string) ([]model.PickingStock, error) {
	if len(goodIDs) == 0 {
		return nil, nil
	}
	rows, err := r.pool.Query(ctx, `
		SELECT s.good_id::text, b.production_date, sum(s.qty)::float8
		FROM stock s
		JOIN cells c ON c.id = s.cell_id
		JOIN batches b ON b.id = s.batch_id
		JOIN internal_warehouses iw ON iw.id = s.internal_warehouse_id
		WHERE c.warehouse_id = $1 AND NOT c.is_default AND NOT c.is_shipping
		  AND iw.allow_picking AND s.good_id = ANY($2::uuid[]) AND s.qty > 0
		GROUP BY s.good_id, b.production_date`, warehouseID, goodIDs)
	if err != nil {
		return nil, fmt.Errorf("остаток для сборки: %w", err)
	}
	defer rows.Close()
	var out []model.PickingStock
	for rows.Next() {
		var s model.PickingStock
		if err := rows.Scan(&s.GoodID, &s.BatchDate, &s.Qty); err != nil {
			return nil, fmt.Errorf("остаток для сборки: %w", err)
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// Load записывает загрузку реестра одной транзакцией.
//
// Что: строка picking_loads и правки заказов по плану. Зачем: план строится по состоянию базы, и
// две загрузки одной даты не должны строить его по одному и тому же прошлому. Как: под
// advisory-блокировкой склада и даты читаются заказы этой даты, build строит по ним план, план
// пишется в ту же транзакцию. Возвращает id загрузки и план.
func (r *PickingRepository) Load(
	ctx context.Context,
	in model.PickingLoadInput,
	build func(existing []model.PickingExistingOrder) ([]model.PickingOrderPlan, error),
) (string, []model.PickingOrderPlan, error) {
	var loadID string
	var plans []model.PickingOrderPlan
	err := WithinTx(ctx, r.pool, func(q Querier) error {
		if _, err := q.Exec(ctx, `SELECT pg_advisory_xact_lock($1, hashtext($2))`,
			pickingLoadLockKey, in.WarehouseID+in.RegistryDate.Format(time.DateOnly)); err != nil {
			return fmt.Errorf("блокировка загрузки реестра: %w", err)
		}
		existing, err := existingPickingOrders(ctx, q, in.WarehouseID, in.RegistryDate)
		if err != nil {
			return err
		}
		if plans, err = build(existing); err != nil {
			return err
		}
		if err := q.QueryRow(ctx, `
			INSERT INTO picking_loads (warehouse_id, registry_date, file_name, uploaded_by)
			VALUES ($1, $2, $3, $4) RETURNING id::text`,
			in.WarehouseID, in.RegistryDate, in.FileName, in.UploadedBy).Scan(&loadID); err != nil {
			return fmt.Errorf("загрузка реестра: %w", err)
		}
		for i := range plans {
			if err := applyPickingPlan(ctx, q, in, loadID, &plans[i]); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return "", nil, err
	}
	return loadID, plans, nil
}

// applyPickingPlan пишет план одного заказа. Правила по статусу — docs/picking.md, «Загрузка и
// повторы»: отгруженный заказ получает только правки и пометку, остальные — новый план.
func applyPickingPlan(ctx context.Context, q Querier, in model.PickingLoadInput, loadID string, p *model.PickingOrderPlan) error {
	switch p.Kind {
	case model.PickingOrderNew:
		h := p.Header
		if err := q.QueryRow(ctx, `
			INSERT INTO picking_orders (warehouse_id, registry_date, invoice_number, order_number, order_date,
			                            direction, client, address, has_unknown, created_load_id, updated_load_id)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $10) RETURNING id::text`,
			in.WarehouseID, in.RegistryDate, h.InvoiceNumber, h.OrderNumber, h.OrderDate,
			h.Direction, h.Client, h.Address, h.HasUnknown, loadID).Scan(&p.ExistingID); err != nil {
			return fmt.Errorf("заказ сборки %s: %w", h.OrderNumber, err)
		}
		return upsertPickingLines(ctx, q, p.ExistingID, p.Lines)

	case model.PickingOrderDeleted:
		if _, err := q.Exec(ctx, `
			UPDATE picking_orders
			SET deleted_at = now(), changed_after_shipment = changed_after_shipment OR status = 'shipped'
			WHERE id = $1`, p.ExistingID); err != nil {
			return fmt.Errorf("удаление заказа сборки: %w", err)
		}
		return insertPickingChanges(ctx, q, p.ExistingID, loadID, p.Status, p.Changes)

	case model.PickingOrderUnchanged:
		// Шапка и ячейки могли поменяться и без правки строк: план берёт новые.
		if p.Frozen {
			_, err := q.Exec(ctx, `UPDATE picking_orders SET updated_load_id = $2 WHERE id = $1`, p.ExistingID, loadID)
			return wrapPickingErr(err)
		}
	}

	if p.Frozen {
		if _, err := q.Exec(ctx, `
			UPDATE picking_orders
			SET updated_load_id = $2, deleted_at = NULL, changed_after_shipment = true
			WHERE id = $1`, p.ExistingID, loadID); err != nil {
			return fmt.Errorf("пометка отгруженного заказа: %w", err)
		}
		return insertPickingChanges(ctx, q, p.ExistingID, loadID, p.Status, p.Changes)
	}

	h := p.Header
	if _, err := q.Exec(ctx, `
		UPDATE picking_orders
		SET invoice_number = $2, order_date = $3, direction = $4, client = $5, address = $6,
		    has_unknown = $7, updated_load_id = $8, deleted_at = NULL,
		    status           = CASE WHEN $9 THEN 'in_progress' ELSE status END,
		    assignee_id      = CASE WHEN $9 THEN picked_by ELSE assignee_id END,
		    taken_at         = CASE WHEN $9 THEN now() ELSE taken_at END,
		    last_activity_at = CASE WHEN $9 THEN now() ELSE last_activity_at END
		WHERE id = $1`,
		p.ExistingID, h.InvoiceNumber, h.OrderDate, h.Direction, h.Client, h.Address,
		h.HasUnknown, loadID, p.Reopen); err != nil {
		return fmt.Errorf("заказ сборки %s: %w", h.OrderNumber, err)
	}
	if len(p.RemovedLineIDs) > 0 {
		if _, err := q.Exec(ctx, `
			UPDATE picking_order_lines SET removed_at = now() WHERE id = ANY($1::uuid[])`,
			p.RemovedLineIDs); err != nil {
			return fmt.Errorf("убранные строки заказа: %w", err)
		}
	}
	if err := upsertPickingLines(ctx, q, p.ExistingID, p.Lines); err != nil {
		return err
	}
	return insertPickingChanges(ctx, q, p.ExistingID, loadID, p.Status, p.Changes)
}

// upsertPickingLines обновляет строки, что уже есть у заказа, и заводит новые в конце порядка.
func upsertPickingLines(ctx context.Context, q Querier, orderID string, lines []model.PickingPlanLine) error {
	var next int
	if err := q.QueryRow(ctx, `
		SELECT coalesce(max(line_no), 0) FROM picking_order_lines WHERE order_id = $1`, orderID).Scan(&next); err != nil {
		return fmt.Errorf("порядок строк заказа: %w", err)
	}
	for _, l := range lines {
		if l.ExistingID != "" {
			if _, err := q.Exec(ctx, `
				UPDATE picking_order_lines
				SET good_name = $2, good_id = $3, registry_cell = $4, cell_id = $5, plan_qty = $6, removed_at = NULL
				WHERE id = $1`, l.ExistingID, l.GoodName, l.GoodID, l.RegistryCell, l.CellID, l.Qty); err != nil {
				return fmt.Errorf("строка заказа сборки %s: %w", l.GoodCode, err)
			}
			continue
		}
		next++
		if _, err := q.Exec(ctx, `
			INSERT INTO picking_order_lines (order_id, line_no, good_code, good_name, good_id, batch_date,
			                                 registry_cell, cell_id, plan_qty)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
			orderID, next, l.GoodCode, l.GoodName, l.GoodID, l.BatchDate, l.RegistryCell, l.CellID, l.Qty); err != nil {
			return fmt.Errorf("строка заказа сборки %s: %w", l.GoodCode, err)
		}
	}
	return nil
}

func insertPickingChanges(ctx context.Context, q Querier, orderID, loadID, status string, changes []model.PickingChange) error {
	for _, c := range changes {
		var code, name *string
		if c.GoodCode != "" {
			code, name = &c.GoodCode, &c.GoodName
		}
		if _, err := q.Exec(ctx, `
			INSERT INTO picking_order_changes (order_id, load_id, kind, good_code, good_name, batch_date,
			                                   old_qty, new_qty, order_status)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
			orderID, loadID, c.Kind, code, name, c.BatchDate, c.OldQty, c.NewQty, status); err != nil {
			return fmt.Errorf("история заказа сборки: %w", err)
		}
	}
	return nil
}

func wrapPickingErr(err error) error {
	if err != nil {
		return fmt.Errorf("заказ сборки: %w", err)
	}
	return nil
}
