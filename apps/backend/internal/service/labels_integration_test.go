package service_test

import (
	"bytes"
	"context"
	"errors"
	"testing"

	"craftwms/internal/repository"
	"craftwms/internal/service"
	"craftwms/internal/testutil"
)

func TestCellLabelsPDF(t *testing.T) {
	pool := testutil.StartPostgres(t)
	ctx := context.Background()

	// Склад SHB + ячейки (одна напольная).
	var wh string
	if err := pool.QueryRow(ctx, `INSERT INTO warehouses (code,name) VALUES ('SHB','Шабулина') RETURNING id::text`).Scan(&wh); err != nil {
		t.Fatalf("seed warehouse: %v", err)
	}
	for _, c := range []struct {
		addr  string
		floor bool
	}{{"M1-1-1-1", true}, {"M1-1-2-1", false}, {"M1-1-10-1", false}} {
		if _, err := pool.Exec(ctx, `INSERT INTO cells (warehouse_id,address,is_floor) VALUES ($1::uuid,$2,$3)`, wh, c.addr, c.floor); err != nil {
			t.Fatalf("seed cell %s: %v", c.addr, err)
		}
	}

	svc := service.NewLabelService(repository.NewWarehouseRepository(pool), repository.NewCellRepository(pool))

	pdf, err := svc.CellLabelsPDF(ctx, "SHB")
	if err != nil {
		t.Fatalf("CellLabelsPDF: %v", err)
	}
	if !bytes.HasPrefix(pdf, []byte("%PDF")) {
		t.Fatalf("ожидался PDF (%%PDF-заголовок)")
	}
	if len(pdf) < 2000 {
		t.Fatalf("PDF подозрительно мал (%d байт)", len(pdf))
	}

	// Неизвестный склад → ErrNotFound (хендлер → 404).
	if _, err := svc.CellLabelsPDF(ctx, "NOPE"); !errors.Is(err, repository.ErrNotFound) {
		t.Fatalf("неизвестный склад: ожидалась ErrNotFound, получено %v", err)
	}
}
