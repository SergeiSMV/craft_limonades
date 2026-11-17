package service_test

import (
	"context"
	"errors"
	"testing"

	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/internal/service"
	"craftwms/internal/testutil"
)

// TestNormalizeFloorAddress - адрес напольной ячейки: заглавными, «Н» окончания кириллицей,
// стеллаж перед «-Н-П» обязателен.
func TestNormalizeFloorAddress(t *testing.T) {
	ok := map[string]string{
		"D-Н-П":   "D-Н-П",
		" d-h-п ": "D-Н-П",
		"с-н-п":   "С-Н-П",
		"M1-Н-П":  "M1-Н-П",
		"А-2-Н-П": "А-2-Н-П",
	}
	for in, want := range ok {
		got, err := service.NormalizeFloorAddress(in)
		if err != nil || got != want {
			t.Errorf("NormalizeFloorAddress(%q) = %q, %v; ждали %q", in, got, err, want)
		}
	}
	for _, in := range []string{"", "Н-П", "D-1-1-1", "D Н-П", "D--Н-П", "ПРИЁМКА", "D-Н-П-1"} {
		if _, err := service.NormalizeFloorAddress(in); !errors.Is(err, service.ErrInvalidFloorAddress) {
			t.Errorf("NormalizeFloorAddress(%q): ждали ErrInvalidFloorAddress, получили %v", in, err)
		}
	}
}

// TestFloorCells_lifecycle - напольная ячейка: добавить, увидеть на странице, переименовать,
// не удалить с товаром, удалить пустую, вернуть удалённую тем же адресом. Ячейку стеллажа так не
// переименовать и не удалить.
func TestFloorCells_lifecycle(t *testing.T) {
	pool := testutil.StartPostgres(t)
	ctx := context.Background()
	importFile(t, pool, rackLabelsSamplePath)
	svc := newCellSetupSvc(pool)

	cell, err := svc.CreateFloorCell(ctx, "SHB", model.FloorCellInput{Address: "d-h-п"})
	if err != nil {
		t.Fatalf("CreateFloorCell: %v", err)
	}
	if cell.Address != "D-Н-П" {
		t.Fatalf("адрес %q, ждали D-Н-П", cell.Address)
	}
	if _, err := svc.CreateFloorCell(ctx, "SHB", model.FloorCellInput{Address: "D-Н-П"}); !errors.Is(err, repository.ErrCellExists) {
		t.Fatalf("повтор адреса: ждали ErrCellExists, получили %v", err)
	}

	setup, err := svc.Setup(ctx, "SHB")
	if err != nil {
		t.Fatalf("Setup: %v", err)
	}
	var rackCell string
	found := false
	for _, c := range setup.Cells {
		if c.ID == cell.ID {
			found = true
			if !c.IsFloorStorage || c.RackID != nil || c.SideCard {
				t.Fatalf("напольная ячейка на странице: %+v", c)
			}
		} else if c.IsFloorStorage {
			t.Fatalf("ячейка стеллажа %s стала напольной", c.Address)
		} else if rackCell == "" {
			rackCell = c.ID
		}
	}
	if !found {
		t.Fatal("напольной ячейки нет на странице")
	}

	renamed, err := svc.RenameFloorCell(ctx, "SHB", cell.ID, model.FloorCellInput{Address: "M1-Н-П"})
	if err != nil || renamed.Address != "M1-Н-П" {
		t.Fatalf("RenameFloorCell: %+v, %v", renamed, err)
	}
	if _, err := svc.RenameFloorCell(ctx, "SHB", rackCell, model.FloorCellInput{Address: "B-Н-П"}); !errors.Is(err, repository.ErrNotFound) {
		t.Fatalf("переименовать ячейку стеллажа: ждали ErrNotFound, получили %v", err)
	}
	if err := svc.DeleteFloorCell(ctx, "SHB", rackCell); !errors.Is(err, repository.ErrNotFound) {
		t.Fatalf("удалить ячейку стеллажа: ждали ErrNotFound, получили %v", err)
	}

	// С товаром не удаляется.
	var good, batch string
	if err := pool.QueryRow(ctx, `INSERT INTO goods (name, uom) VALUES ('Пиво','шт') RETURNING id::text`).Scan(&good); err != nil {
		t.Fatalf("товар: %v", err)
	}
	if err := pool.QueryRow(ctx, `INSERT INTO batches (good_id, production_date) VALUES ($1::uuid,'2026-10-01') RETURNING id::text`, good).Scan(&batch); err != nil {
		t.Fatalf("партия: %v", err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO stock (cell_id, good_id, batch_id, qty, internal_warehouse_id) SELECT $1::uuid,$2::uuid,$3::uuid,2, id FROM internal_warehouses WHERE is_default`, cell.ID, good, batch); err != nil {
		t.Fatalf("остаток: %v", err)
	}
	if err := svc.DeleteFloorCell(ctx, "SHB", cell.ID); !errors.Is(err, repository.ErrCellNotEmpty) {
		t.Fatalf("удалить с товаром: ждали ErrCellNotEmpty, получили %v", err)
	}
	if _, err := pool.Exec(ctx, `UPDATE stock SET qty = 0 WHERE cell_id = $1::uuid`, cell.ID); err != nil {
		t.Fatalf("обнулить остаток: %v", err)
	}
	if err := svc.DeleteFloorCell(ctx, "SHB", cell.ID); err != nil {
		t.Fatalf("удалить пустую: %v", err)
	}
	setup, _ = svc.Setup(ctx, "SHB")
	for _, c := range setup.Cells {
		if c.ID == cell.ID {
			t.Fatal("удалённая ячейка осталась на странице")
		}
	}

	again, err := svc.CreateFloorCell(ctx, "SHB", model.FloorCellInput{Address: "M1-Н-П"})
	if err != nil || again.ID != cell.ID {
		t.Fatalf("вернуть удалённую: %+v, %v; ждали id %s", again, err, cell.ID)
	}
}

// TestFloorCells_receivingCell - после миграции 44 ячейка приёмки - «ПРИЁМКА», «С-Н-П» -
// обычная напольная; импорт ячеек не заводит вторую ячейку приёмки и ставит признак пола по адресу.
func TestFloorCells_receivingCell(t *testing.T) {
	pool := testutil.StartPostgres(t)
	ctx := context.Background()
	importFile(t, pool, rackLabelsSamplePath)

	var receiving string
	if err := pool.QueryRow(ctx, `
		SELECT c.address FROM cells c JOIN warehouses w ON w.id = c.warehouse_id
		WHERE w.code = 'SHB' AND c.is_default`).Scan(&receiving); err != nil {
		t.Fatalf("ячейка приёмки: %v", err)
	}
	if receiving != model.DefaultCellAddress {
		t.Fatalf("ячейка приёмки %q, ждали %q", receiving, model.DefaultCellAddress)
	}

	svc := newCellSetupSvc(pool)
	if _, err := svc.CreateFloorCell(ctx, "SHB", model.FloorCellInput{Address: "С-Н-П"}); err != nil {
		t.Fatalf("С-Н-П напольной: %v", err)
	}
	// Повторный импорт: ячейка приёмки прежняя, одна.
	importFile(t, pool, rackLabelsSamplePath)
	var n int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM cells WHERE is_default`).Scan(&n); err != nil || n != 1 {
		t.Fatalf("ячеек приёмки %d, %v; ждали 1", n, err)
	}
}
