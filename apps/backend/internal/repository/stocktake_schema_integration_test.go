package repository_test

import (
	"context"
	"testing"
)

// P10-01: схема пересчёта держит свои правила сама — документ с областью, ячейки с этапами,
// строки «ожидалось / факт» трёх видов (россыпь, короб целиком, товар в коробе), марки,
// задание вида stocktake. Тест проверяет, что база принимает правильное и отвергает неверное.
func TestStocktakeSchema(t *testing.T) {
	pf := setupPutaway(t)
	ctx := context.Background()
	exec := func(sql string, args ...any) error {
		_, err := pf.pool.Exec(ctx, sql, args...)
		return err
	}
	mustOK := func(what, sql string, args ...any) {
		t.Helper()
		if err := exec(sql, args...); err != nil {
			t.Fatalf("%s: %v", what, err)
		}
	}
	var st, stCell, lu, loose string
	mustScan(t, pf.pool, `INSERT INTO stocktakes (warehouse_id, scope_kind, created_by)
		VALUES ($1::uuid, 'cells', $2::uuid) RETURNING id::text`, &st, pf.wh, pf.user)
	mustOK("область — ячейка", `INSERT INTO stocktake_scope (stocktake_id, cell_id) VALUES ($1::uuid, $2::uuid)`, st, pf.cellB)
	mustOK("область — товар", `INSERT INTO stocktake_scope (stocktake_id, good_id) VALUES ($1::uuid, $2::uuid)`, st, pf.good)
	mustOK("область — внутренний склад", `INSERT INTO stocktake_scope (stocktake_id, internal_warehouse_id)
		VALUES ($1::uuid, $2::uuid)`, st, pf.iwhDefect)
	mustScan(t, pf.pool, `INSERT INTO stocktake_cells (stocktake_id, cell_id, status, taken_by, taken_at, started_at)
		VALUES ($1::uuid, $2::uuid, 'counting', $3::uuid, now(), now()) RETURNING id::text`, &stCell, st, pf.cellB, pf.user)
	mustOK("ячейка взята, работник идёт к ней", `INSERT INTO stocktake_cells (stocktake_id, cell_id, status, taken_by, taken_at)
		VALUES ($1::uuid, $2::uuid, 'taken', $3::uuid, now())`, st, pf.cellA, pf.user)
	mustScan(t, pf.pool, `INSERT INTO load_units (id, kind) VALUES (gen_random_uuid(), 'box') RETURNING id::text`, &lu)

	// Три вида строк: россыпь, короб целиком, товар во вскрытом коробе.
	mustScan(t, pf.pool, `INSERT INTO stocktake_lines (stocktake_cell_id, good_id, batch_id, internal_warehouse_id, expected_qty)
		VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, 5) RETURNING id::text`, &loose, stCell, pf.good, pf.batch, pf.iwh)
	mustOK("короб целиком", `INSERT INTO stocktake_lines (stocktake_cell_id, load_unit_id, internal_warehouse_id, expected_qty, fact_qty)
		VALUES ($1::uuid, $2::uuid, $3::uuid, 1, 1)`, stCell, lu, pf.iwh)
	mustOK("товар в коробе", `INSERT INTO stocktake_lines (stocktake_cell_id, load_unit_id, good_id, batch_id, internal_warehouse_id, expected_qty)
		VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, $5::uuid, 12)`, stCell, lu, pf.good, pf.batch, pf.iwh)
	mustOK("брак той же позиции — своя строка", `INSERT INTO stocktake_lines (stocktake_cell_id, good_id, batch_id, internal_warehouse_id)
		VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid)`, stCell, pf.good, pf.batch, pf.iwhDefect)
	mustOK("марка ожидалась", `INSERT INTO stocktake_marks (stocktake_cell_id, cis, line_id, expected)
		VALUES ($1::uuid, '0104600000000017215L1', $2::uuid, true)`, stCell, loose)
	mustOK("задание на пересчёт", `INSERT INTO warehouse_tasks (kind, warehouse_id, stocktake_id)
		VALUES ('stocktake', $1::uuid, $2::uuid)`, pf.wh, st)

	var supplier, freeCell string
	mustScan(t, pf.pool, `INSERT INTO suppliers (name) VALUES ('Поставщик') RETURNING id::text`, &supplier)
	mustScan(t, pf.pool, `INSERT INTO cells (warehouse_id, address) VALUES ($1::uuid, 'X') RETURNING id::text`, &freeCell, pf.wh)

	// Отказы — в одной транзакции на одном соединении: каждый под своей точкой отката, чтобы
	// ошибка одного не прерывала проверку остальных.
	tx, err := pf.pool.Begin(ctx)
	if err != nil {
		t.Fatalf("begin: %v", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	for _, c := range []struct{ what, sql string }{
		{"два объекта в строке области", `INSERT INTO stocktake_scope (stocktake_id, cell_id, supplier_id)
			VALUES ('` + st + `', '` + pf.cellA + `', '` + supplier + `')`},
		{"строка области без объекта", `INSERT INTO stocktake_scope (stocktake_id) VALUES ('` + st + `')`},
		{"повтор строки той же позиции", `INSERT INTO stocktake_lines (stocktake_cell_id, good_id, batch_id, internal_warehouse_id)
			VALUES ('` + stCell + `', '` + pf.good + `', '` + pf.batch + `', '` + pf.iwh + `')`},
		{"короб целиком — не штучно", `INSERT INTO stocktake_lines (stocktake_cell_id, load_unit_id, internal_warehouse_id, expected_qty)
			VALUES ('` + stCell + `', gen_random_uuid(), '` + pf.iwh + `', 2)`},
		{"товар без партии", `INSERT INTO stocktake_lines (stocktake_cell_id, good_id, internal_warehouse_id)
			VALUES ('` + stCell + `', '` + pf.good + `', '` + pf.iwh + `')`},
		{"строка ни о чём", `INSERT INTO stocktake_lines (stocktake_cell_id, internal_warehouse_id)
			VALUES ('` + stCell + `', '` + pf.iwh + `')`},
		{"начатая ячейка без момента начала", `INSERT INTO stocktake_cells (stocktake_id, cell_id, status, taken_by, taken_at)
			VALUES ('` + st + `', '` + freeCell + `', 'counting', '` + pf.user + `', now())`},
		{"взятая ячейка без работника", `INSERT INTO stocktake_cells (stocktake_id, cell_id, status)
			VALUES ('` + st + `', '` + freeCell + `', 'taken')`},
		{"свободная ячейка с работником", `INSERT INTO stocktake_cells (stocktake_id, cell_id, taken_by, taken_at)
			VALUES ('` + st + `', '` + freeCell + `', '` + pf.user + `', now())`},
		{"повтор объекта области", `INSERT INTO stocktake_scope (stocktake_id, good_id) VALUES ('` + st + `', '` + pf.good + `')`},
		{"закрытый документ без момента закрытия", `UPDATE stocktakes SET status = 'closed' WHERE id = '` + st + `'`},
		{"марка ни ожидалась, ни найдена", `INSERT INTO stocktake_marks (stocktake_cell_id, cis, line_id)
			VALUES ('` + stCell + `', '0104600000000017215L2', '` + loose + `')`},
		{"задание на пересчёт без документа", `INSERT INTO warehouse_tasks (kind, warehouse_id)
			VALUES ('stocktake', '` + pf.wh + `')`},
		{"второе задание на тот же пересчёт", `INSERT INTO warehouse_tasks (kind, warehouse_id, stocktake_id)
			VALUES ('stocktake', '` + pf.wh + `', '` + st + `')`},
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
