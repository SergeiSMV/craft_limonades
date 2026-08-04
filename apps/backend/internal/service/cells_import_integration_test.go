package service_test

import (
	"context"
	"os"
	"testing"

	"craftwms/internal/testutil"
)

const cellsSamplePath = "../importer/testdata/cells_sample.xlsx"

// TestImportCells_realFile — полный импорт реального файла ячеек в живой Postgres:
// заводится физический склад + 125 ячеек с признаком floor; повторный импорт идемпотентен.
func TestImportCells_realFile(t *testing.T) {
	pool := testutil.StartPostgres(t)
	svc := newImportSvc(pool)
	ctx := context.Background()

	// --- Первый импорт ---
	f, err := os.Open(cellsSamplePath)
	if err != nil {
		t.Fatalf("открыть образец: %v", err)
	}
	rep, err := svc.ImportCells(ctx, f, "SHB", "Шабулина")
	_ = f.Close()
	if err != nil {
		t.Fatalf("ImportCells: %v", err)
	}

	if rep.CellsCreated != 125 || rep.CellsUpdated != 0 {
		t.Errorf("отчёт: ожидалось created=125 updated=0, получено created=%d updated=%d", rep.CellsCreated, rep.CellsUpdated)
	}
	if len(rep.Skipped) != 0 {
		t.Errorf("ожидалось 0 пропущенных, получено %d: %+v", len(rep.Skipped), rep.Skipped)
	}
	// В БД: 1 склад, 125 ячеек, 25 напольных.
	if got := countRows(t, pool, "warehouses"); got != 1 {
		t.Errorf("складов: ожидалось 1, получено %d", got)
	}
	if got := countRows(t, pool, "cells"); got != 125 {
		t.Errorf("ячеек: ожидалось 125, получено %d", got)
	}
	var floors int
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM cells WHERE is_floor").Scan(&floors); err != nil {
		t.Fatal(err)
	}
	if floors != 25 {
		t.Errorf("напольных ячеек: ожидалось 25, получено %d", floors)
	}

	// Ячейка принадлежит заведённому складу «Шабулина» (code SHB).
	var whCode string
	if err := pool.QueryRow(ctx, `
		SELECT w.code FROM cells c JOIN warehouses w ON w.id = c.warehouse_id
		WHERE c.address = 'M1-1-1-1'`).Scan(&whCode); err != nil {
		t.Fatalf("склад ячейки M1-1-1-1: %v", err)
	}
	if whCode != "SHB" {
		t.Errorf("склад ячейки: ожидалось SHB, получено %s", whCode)
	}

	// --- Повторный импорт того же файла: идемпотентность, без дублей ---
	f2, err := os.Open(cellsSamplePath)
	if err != nil {
		t.Fatal(err)
	}
	rep2, err := svc.ImportCells(ctx, f2, "SHB", "Шабулина")
	_ = f2.Close()
	if err != nil {
		t.Fatalf("повторный ImportCells: %v", err)
	}
	if rep2.CellsCreated != 0 || rep2.CellsUpdated != 125 {
		t.Errorf("повтор: ожидалось created=0 updated=125, получено created=%d updated=%d", rep2.CellsCreated, rep2.CellsUpdated)
	}
	if got := countRows(t, pool, "cells"); got != 125 {
		t.Errorf("после повтора ячеек: ожидалось 125 (без дублей), получено %d", got)
	}
	if got := countRows(t, pool, "warehouses"); got != 1 {
		t.Errorf("после повтора складов: ожидалось 1 (без дублей), получено %d", got)
	}
}
