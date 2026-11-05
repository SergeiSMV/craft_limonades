package repository_test

import (
	"context"
	"testing"

	"craftwms/internal/repository"
)

// ADHOC-60: версии данных по областям повышают триггеры миграции 43 — в транзакции правки и
// только если оператор изменил строки.
func TestDataVersions(t *testing.T) {
	fx := setupStock(t)
	ctx := context.Background()
	repo := repository.NewDataVersionRepository(fx.pool)
	versions := func() map[string]int64 {
		t.Helper()
		v, err := repo.DataVersions(ctx)
		if err != nil {
			t.Fatal(err)
		}
		return v
	}
	exec := func(sql string, args ...any) {
		t.Helper()
		if _, err := fx.pool.Exec(ctx, sql, args...); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
	}

	before := versions()
	for _, d := range []string{"goods", "cells", "settings", "contents", "tasks", "problems", "stocktakes", "documents"} {
		if before[d] == 0 {
			t.Fatalf("нет области %q: %v", d, before)
		}
	}

	// Правка товара — только «номенклатура».
	exec(`UPDATE goods SET name = name || ' ' WHERE id = $1::uuid`, fx.good)
	after := versions()
	if after["goods"] != before["goods"]+1 || after["contents"] != before["contents"] || after["cells"] != before["cells"] {
		t.Fatalf("правка товара: было %v, стало %v", before, after)
	}

	// Охранный UPDATE без строк — версия не меняется.
	exec(`UPDATE goods SET name = 'x' WHERE id = '00000000-0000-4000-8000-000000000999'::uuid`)
	if v := versions(); v["goods"] != after["goods"] {
		t.Fatalf("UPDATE без строк повысил версию: %d → %d", after["goods"], v["goods"])
	}

	// Один оператор на много строк — одно повышение, а не по строке.
	exec(`UPDATE cells SET address = address WHERE id IN ($1::uuid, $2::uuid)`, fx.cellA, fx.cellB)
	if v := versions(); v["cells"] != before["cells"]+1 {
		t.Fatalf("две ячейки одним оператором: %d → %d", before["cells"], v["cells"])
	}

	// Вставка и удаление остатка — «остатки».
	exec(`INSERT INTO stock (cell_id, good_id, batch_id, internal_warehouse_id, qty)
		VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, 1)`, fx.cellA, fx.good, fx.batch, fx.iwh)
	exec(`DELETE FROM stock WHERE cell_id = $1::uuid`, fx.cellA)
	if v := versions(); v["contents"] != before["contents"]+2 {
		t.Fatalf("вставка и удаление остатка: %d → %d", before["contents"], v["contents"])
	}

	// Откат транзакции откатывает и версию: клиент не увидит версию без данных.
	tx, err := fx.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `UPDATE goods SET name = name WHERE id = $1::uuid`, fx.good); err != nil {
		t.Fatal(err)
	}
	if err := tx.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	if v := versions(); v["goods"] != after["goods"] {
		t.Fatalf("откат повысил версию: %d → %d", after["goods"], v["goods"])
	}
}
