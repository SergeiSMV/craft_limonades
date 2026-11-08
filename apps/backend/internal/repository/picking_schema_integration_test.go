package repository_test

import (
	"context"
	"testing"

	"craftwms/internal/repository"
)

// P9-02: схема сборки держит свои правила сама — заказ со статусами WMS и исполнителем, строки
// плана по тройке «заказ + код + партия», история правок, короба отгрузки «N из M», пики
// россыпью и из короба, марки пика; ячейка отгрузки одна на склад и не ячейка приёмки.
// Тест проверяет, что база принимает правильное и отвергает неверное.
func TestPickingSchema(t *testing.T) {
	pf := setupPutaway(t)
	ctx := context.Background()
	mustOK := func(what, sql string, args ...any) {
		t.Helper()
		if _, err := pf.pool.Exec(ctx, sql, args...); err != nil {
			t.Fatalf("%s: %v", what, err)
		}
	}

	// Ячейка отгрузки заводится складу так же, как ячейка приёмки, и повтор не плодит вторую.
	cells := repository.NewCellRepository(pf.pool)
	ship, err := cells.EnsureShipping(ctx, pf.pool, pf.wh)
	if err != nil {
		t.Fatalf("EnsureShipping: %v", err)
	}
	if again, err := cells.EnsureShipping(ctx, pf.pool, pf.wh); err != nil || again != ship {
		t.Fatalf("повторный EnsureShipping: %s, %v (ждали %s)", again, err, ship)
	}

	var load, order, line, unknownLine, lu, storageLU, pick string
	mustScan(t, pf.pool, `INSERT INTO picking_loads (warehouse_id, registry_date, file_name, uploaded_by)
		VALUES ($1::uuid, '2026-11-09', 'Реестр.xlsx', $2::uuid) RETURNING id::text`, &load, pf.wh, pf.user)
	mustScan(t, pf.pool, `INSERT INTO picking_orders (warehouse_id, registry_date, invoice_number, order_number,
		    client, created_load_id, updated_load_id)
		VALUES ($1::uuid, '2026-11-09', '20961', '15512', 'ИП Суслова', $2::uuid, $2::uuid) RETURNING id::text`,
		&order, pf.wh, load)
	mustOK("второй заказ той же накладной", `INSERT INTO picking_orders (warehouse_id, registry_date, invoice_number,
		    order_number, created_load_id, updated_load_id)
		VALUES ($1::uuid, '2026-11-09', '20961', '15513', $2::uuid, $2::uuid)`, pf.wh, load)
	mustOK("тот же номер заказа другой датой", `INSERT INTO picking_orders (warehouse_id, registry_date, invoice_number,
		    order_number, created_load_id, updated_load_id)
		VALUES ($1::uuid, '2026-11-10', '20961', '15512', $2::uuid, $2::uuid)`, pf.wh, load)
	mustScan(t, pf.pool, `INSERT INTO picking_order_lines (order_id, line_no, good_code, good_id, batch_date,
		    registry_cell, cell_id, plan_qty)
		VALUES ($1::uuid, 1, '00000016147', $2::uuid, '2026-09-11', 'С-1-1-1', $3::uuid, 5) RETURNING id::text`,
		&line, order, pf.good, pf.cellA)
	mustOK("тот же товар другой партией", `INSERT INTO picking_order_lines (order_id, line_no, good_code, good_id,
		    batch_date, plan_qty)
		VALUES ($1::uuid, 2, '00000016147', $2::uuid, '2026-10-01', 1)`, order, pf.good)
	mustScan(t, pf.pool, `INSERT INTO picking_order_lines (order_id, line_no, good_code, plan_qty)
		VALUES ($1::uuid, 3, '00000099999', 2) RETURNING id::text`, &unknownLine, order)
	mustOK("правка строки", `INSERT INTO picking_order_changes (order_id, load_id, kind, good_code, batch_date,
		    old_qty, new_qty, order_status)
		VALUES ($1::uuid, $2::uuid, 'qty_changed', '00000016147', '2026-09-11', 4, 5, 'new')`, order, load)
	mustOK("заказ удалён", `INSERT INTO picking_order_changes (order_id, load_id, kind, order_status)
		VALUES ($1::uuid, $2::uuid, 'order_deleted', 'new')`, order, load)

	mustOK("кладовщик взял заказ", `UPDATE picking_orders SET status = 'in_progress', assignee_id = $2::uuid,
		    taken_at = now(), last_activity_at = now() WHERE id = $1::uuid`, order, pf.user)
	mustScan(t, pf.pool, `INSERT INTO load_units (id, kind) VALUES (gen_random_uuid(), 'box') RETURNING id::text`, &lu)
	mustScan(t, pf.pool, `INSERT INTO load_units (id, kind, cell_id, status) VALUES (gen_random_uuid(), 'box', $1::uuid, 'placed')
		RETURNING id::text`, &storageLU, pf.cellB)
	mustOK("короб отгрузки 1", `INSERT INTO picking_boxes (load_unit_id, order_id, seq, created_by)
		VALUES ($1::uuid, $2::uuid, 1, $3::uuid)`, lu, order, pf.user)
	mustScan(t, pf.pool, `INSERT INTO picking_picks (order_id, line_id, box_id, good_id, batch_id, source_cell_id,
		    internal_warehouse_id, qty, picked_by)
		VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, $5::uuid, $6::uuid, $7::uuid, 2, $8::uuid) RETURNING id::text`,
		&pick, order, line, lu, pf.good, pf.batch, pf.cellA, pf.iwh, pf.user)
	mustOK("пик из короба хранения", `INSERT INTO picking_picks (order_id, line_id, box_id, good_id, batch_id,
		    source_cell_id, source_load_unit_id, internal_warehouse_id, qty, picked_by)
		VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, $5::uuid, $6::uuid, $7::uuid, $8::uuid, 1, $9::uuid)`,
		order, line, lu, pf.good, pf.batch, pf.cellB, storageLU, pf.iwh, pf.user)
	mustOK("марка ЧЗ", `INSERT INTO cz_marks (cis, good_id, batch_id, cell_id, internal_warehouse_id)
		VALUES ('0104600000000017215PICK', $1::uuid, $2::uuid, $3::uuid, $4::uuid)`, pf.good, pf.batch, pf.cellA, pf.iwh)
	mustOK("марка пика", `INSERT INTO picking_pick_marks (pick_id, cis) VALUES ($1::uuid, '0104600000000017215PICK')`, pick)
	mustOK("завершить сборку", `UPDATE picking_picks SET state = 'moved', moved_at = now() WHERE order_id = $1::uuid`, order)
	mustOK("заказ собран", `UPDATE picking_orders SET status = 'picked', assignee_id = NULL, picked_by = $2::uuid,
		    picked_at = now(), is_partial = true WHERE id = $1::uuid`, order, pf.user)
	mustOK("возврат из короба на место", `UPDATE picking_picks SET state = 'returned', returned_at = now()
		WHERE id = $1::uuid`, pick)
	mustOK("короб отгружен", `UPDATE load_units SET status = 'shipped', cell_id = NULL WHERE id = $1::uuid`, lu)
	mustOK("заказ отгружен", `UPDATE picking_orders SET status = 'shipped', shipped_by = $2::uuid, shipped_at = now()
		WHERE id = $1::uuid`, order, pf.user)
	mustOK("изменён в 1С после отгрузки", `UPDATE picking_orders SET changed_after_shipment = true WHERE id = $1::uuid`, order)

	// Сборка разрешена складу по умолчанию («Основной», миграция), новый склад — запрещён.
	var mainAllowed, defectAllowed bool
	if err := pf.pool.QueryRow(ctx, `SELECT
		    (SELECT allow_picking FROM internal_warehouses WHERE is_default),
		    (SELECT allow_picking FROM internal_warehouses WHERE id = $1::uuid)`, pf.iwhDefect).
		Scan(&mainAllowed, &defectAllowed); err != nil {
		t.Fatalf("признак сборки складов: %v", err)
	}
	if !mainAllowed || defectAllowed {
		t.Errorf("сборка: основной склад %v (ждали true), новый склад %v (ждали false)", mainAllowed, defectAllowed)
	}

	// Отказы — в одной транзакции на одном соединении, каждый под своей точкой отката.
	tx, err := pf.pool.Begin(ctx)
	if err != nil {
		t.Fatalf("begin: %v", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	for _, c := range []struct{ what, sql string }{
		{"повтор заказа той же даты", `INSERT INTO picking_orders (warehouse_id, registry_date, invoice_number,
			order_number, created_load_id, updated_load_id)
			VALUES ('` + pf.wh + `', '2026-11-09', '20999', '15512', '` + load + `', '` + load + `')`},
		{"неизвестный статус", `UPDATE picking_orders SET status = 'done' WHERE id = '` + order + `'`},
		{"в работе без исполнителя", `UPDATE picking_orders SET status = 'in_progress', assignee_id = NULL,
			shipped_at = NULL, changed_after_shipment = false WHERE id = '` + order + `'`},
		{"новый с исполнителем", `UPDATE picking_orders SET status = 'new', assignee_id = '` + pf.user + `',
			shipped_at = NULL, changed_after_shipment = false WHERE id = '` + order + `'`},
		{"отгружен без момента отгрузки", `UPDATE picking_orders SET shipped_at = NULL WHERE id = '` + order + `'`},
		{"собран без момента сборки", `UPDATE picking_orders SET status = 'picked', picked_at = NULL, shipped_at = NULL,
			changed_after_shipment = false WHERE id = '` + order + `'`},
		{"пометка после отгрузки у неотгруженного", `UPDATE picking_orders SET status = 'picked', shipped_at = NULL
			WHERE id = '` + order + `'`},
		{"повтор тройки строки", `INSERT INTO picking_order_lines (order_id, line_no, good_code, batch_date, plan_qty)
			VALUES ('` + order + `', 9, '00000016147', '2026-09-11', 1)`},
		{"повтор тройки без партии", `INSERT INTO picking_order_lines (order_id, line_no, good_code, plan_qty)
			VALUES ('` + order + `', 9, '00000099999', 1)`},
		{"повтор номера строки", `INSERT INTO picking_order_lines (order_id, line_no, good_code, plan_qty)
			VALUES ('` + order + `', 1, '00000011111', 1)`},
		{"нулевой план", `UPDATE picking_order_lines SET plan_qty = 0 WHERE id = '` + unknownLine + `'`},
		{"правка строки без товара", `INSERT INTO picking_order_changes (order_id, load_id, kind, order_status)
			VALUES ('` + order + `', '` + load + `', 'line_added', 'new')`},
		{"удаление заказа с товаром", `INSERT INTO picking_order_changes (order_id, load_id, kind, good_code, order_status)
			VALUES ('` + order + `', '` + load + `', 'order_deleted', '00000016147', 'new')`},
		{"неизвестная правка", `INSERT INTO picking_order_changes (order_id, load_id, kind, order_status)
			VALUES ('` + order + `', '` + load + `', 'renamed', 'new')`},
		{"повтор номера короба", `INSERT INTO picking_boxes (load_unit_id, order_id, seq, created_by)
			VALUES ('` + storageLU + `', '` + order + `', 1, '` + pf.user + `')`},
		{"пик нулём", `INSERT INTO picking_picks (order_id, line_id, box_id, good_id, batch_id, source_cell_id,
			internal_warehouse_id, qty, picked_by) VALUES ('` + order + `', '` + line + `', '` + lu + `', '` + pf.good + `',
			'` + pf.batch + `', '` + pf.cellA + `', '` + pf.iwh + `', 0, '` + pf.user + `')`},
		{"перенесён без момента", `UPDATE picking_picks SET state = 'moved', moved_at = NULL, returned_at = NULL
			WHERE id = '` + pick + `'`},
		{"в сборке с моментом возврата", `UPDATE picking_picks SET state = 'picking' WHERE id = '` + pick + `'`},
		{"вторая ячейка отгрузки", `INSERT INTO cells (warehouse_id, address, is_shipping)
			VALUES ('` + pf.wh + `', 'ОТГРУЗКА-2', true)`},
		{"отгрузка и приёмка сразу", `UPDATE cells SET is_default = true WHERE id = '` + ship + `'`},
		{"неизвестный статус короба", `UPDATE load_units SET status = 'lost' WHERE id = '` + lu + `'`},
	} {
		if _, err := tx.Exec(ctx, "SAVEPOINT s"); err != nil {
			t.Fatalf("точка отката: %v", err)
		}
		if _, err := tx.Exec(ctx, c.sql); err == nil {
			t.Errorf("%s: база приняла", c.what)
		}
		if _, err := tx.Exec(ctx, "ROLLBACK TO SAVEPOINT s"); err != nil {
			t.Fatalf("откат к точке: %v", err)
		}
	}
}
