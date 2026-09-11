package service_test

import (
	"context"
	"os"
	"testing"

	"craftwms/internal/model"
	"craftwms/internal/testutil"
)

const cellsSamplePath = "../importer/testdata/cells_sample.xlsx"

// TestImportCells_realFile — полный импорт реального файла ячеек в живой Postgres:
// заводится физический склад + 125 ячеек с признаком floor и дефолтная ячейка приёмки;
// повторный импорт идемпотентен.
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
	// В БД: 1 склад, 125 ячеек из файла + дефолтная ячейка приёмки, 25 напольных.
	if got := countRows(t, pool, "warehouses"); got != 1 {
		t.Errorf("складов: ожидалось 1, получено %d", got)
	}
	if got := countRows(t, pool, "cells"); got != 126 {
		t.Errorf("ячеек: ожидалось 126 (125 из файла + дефолтная), получено %d", got)
	}
	// Дефолтная ячейка заводится импортом, а не человеком: склад без неё означал бы,
	// что приёмка на нём невозможна (P4-03). В отчёт она не попадает — отчёт про файл.
	var dfltAddress string
	if err := pool.QueryRow(ctx,
		`SELECT address FROM cells WHERE is_default`).Scan(&dfltAddress); err != nil {
		t.Fatalf("дефолтная ячейка после импорта: %v", err)
	}
	if dfltAddress != model.DefaultCellAddress {
		t.Errorf("дефолтная ячейка: %q, ожидалась %q", dfltAddress, model.DefaultCellAddress)
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
	if got := countRows(t, pool, "cells"); got != 126 {
		t.Errorf("после повтора ячеек: ожидалось 126 (без дублей), получено %d", got)
	}
	// Дефолтная ячейка тоже не двоится: повторный импорт лишь проставляет ей признак.
	var defaults int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM cells WHERE is_default`).Scan(&defaults); err != nil {
		t.Fatal(err)
	}
	if defaults != 1 {
		t.Errorf("дефолтных ячеек после повтора: ожидалась 1, получено %d", defaults)
	}
	if got := countRows(t, pool, "warehouses"); got != 1 {
		t.Errorf("после повтора складов: ожидалось 1 (без дублей), получено %d", got)
	}
}
