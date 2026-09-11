package service_test

import (
	"bytes"
	"context"
	"errors"
	"testing"

	"craftwms/internal/model"
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

	// Дефолтная ячейка приёмки заводится складу автоматически (P4-03), и её адрес «С-Н-П» набран
	// кириллицей — Code128 его не кодирует. Без исключения такой ячейки падала бы печать этикеток
	// ВСЕГО склада, а не только её собственной. Заводим её здесь, чтобы тест ловил именно это.
	cellRepo := repository.NewCellRepository(pool)
	if err := repository.WithinTx(ctx, pool, func(q repository.Querier) error {
		_, err := cellRepo.EnsureDefault(ctx, q, wh)
		return err
	}); err != nil {
		t.Fatalf("дефолтная ячейка: %v", err)
	}

	svc := service.NewLabelService(repository.NewWarehouseRepository(pool), cellRepo)

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

	// Дефолтная ячейка в набор этикеток не попадает. Проверяем на выборке, а не по содержимому
	// PDF: на лист влезает восемь этикеток, и число страниц о составе ничего не говорит.
	labels, err := cellRepo.LabelsByWarehouse(ctx, wh)
	if err != nil {
		t.Fatalf("LabelsByWarehouse: %v", err)
	}
	if len(labels) != 3 {
		t.Errorf("ячеек под этикетки: %d, ожидалось 3 (дефолтная исключается)", len(labels))
	}
	for _, l := range labels {
		if l.Address == model.DefaultCellAddress {
			t.Errorf("дефолтная ячейка %q попала в этикетки — Code128 её адрес не закодирует", l.Address)
		}
	}

	// Неизвестный склад → ErrNotFound (хендлер → 404).
	if _, err := svc.CellLabelsPDF(ctx, "NOPE"); !errors.Is(err, repository.ErrNotFound) {
		t.Fatalf("неизвестный склад: ожидалась ErrNotFound, получено %v", err)
	}
}
