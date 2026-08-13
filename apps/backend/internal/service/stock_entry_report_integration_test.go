package service_test

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/shopspring/decimal"
	"github.com/xuri/excelize/v2"

	"craftwms/internal/repository"
	"craftwms/internal/service"
	"craftwms/internal/testutil"
)

func TestStockEntryReport(t *testing.T) {
	pool := testutil.StartPostgres(t)
	ctx := context.Background()
	seRepo := repository.NewStockEntryRepository(pool)
	svc := service.NewStockEntryReportService(seRepo)

	// Справочники.
	scan := func(sql string, args ...any) string {
		var id string
		if err := pool.QueryRow(ctx, sql, args...).Scan(&id); err != nil {
			t.Fatalf("seed %q: %v", sql, err)
		}
		return id
	}
	wh := scan(`INSERT INTO warehouses(code,name) VALUES('SHB','Шабулина') RETURNING id::text`)
	cell := scan(`INSERT INTO cells(warehouse_id,address) VALUES($1::uuid,'M1-1-1-1') RETURNING id::text`, wh)
	good := scan(`INSERT INTO goods(name,uom,code) VALUES('Кальмар','шт','16121') RETURNING id::text`)
	user := scan(`INSERT INTO users(login,password_hash,full_name) VALUES('90000021','x','Тест') RETURNING id::text`)

	// Закрытая сессия: старт → checkpoint → финал.
	sid, err := seRepo.Create(ctx, wh, user)
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	err = seRepo.Checkpoint(ctx, sid, cell, []repository.StockEntryLineInput{
		{GoodID: good, ProductionDate: "2026-01-15", Qty: decimal.RequireFromString("10.5")},
	}, nil)
	if err != nil {
		t.Fatalf("Checkpoint: %v", err)
	}
	if _, err := seRepo.Finalize(ctx, sid); err != nil {
		t.Fatalf("Finalize: %v", err)
	}

	// Отчёт по закрытой сессии.
	data, filename, err := svc.Report(ctx, sid)
	if err != nil {
		t.Fatalf("Report: %v", err)
	}
	if !bytes.HasPrefix(data, []byte("PK")) {
		t.Fatalf("ожидался .xlsx")
	}
	if !strings.HasPrefix(filename, "vvod-ostatkov-SHB-") || !strings.HasSuffix(filename, ".xlsx") {
		t.Fatalf("имя файла: %q", filename)
	}

	f, err := excelize.OpenReader(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("open xlsx: %v", err)
	}
	defer func() { _ = f.Close() }()
	rows, err := f.GetRows("Ввод остатков")
	if err != nil || len(rows) != 2 {
		t.Fatalf("ожидалось 2 строки (заголовок + 1), получено %d (err %v)", len(rows), err)
	}
	got := rows[1]
	want := []string{"Шабулина", "M1-1-1-1", "16121", "Кальмар", "15.01.2026", "10.5"}
	for i, v := range want {
		if got[i] != v {
			t.Errorf("строка [%d]: ожидалось %q, получено %q", i, v, got[i])
		}
	}

	// Отчёт по НЕзакрытой сессии → ErrSessionNotClosed.
	draft, _ := seRepo.Create(ctx, wh, user)
	if _, _, err := svc.Report(ctx, draft); !errors.Is(err, repository.ErrSessionNotClosed) {
		t.Fatalf("незакрытая сессия: ожидалась ErrSessionNotClosed, получено %v", err)
	}
	// Отчёт по несуществующей сессии → ErrSessionNotFound.
	if _, _, err := svc.Report(ctx, "00000000-0000-0000-0000-0000000000ff"); !errors.Is(err, repository.ErrSessionNotFound) {
		t.Fatalf("несуществующая сессия: ожидалась ErrSessionNotFound, получено %v", err)
	}

	// Список документов: только закрытая сессия (draft не попадает).
	docs, err := svc.ListDocuments(ctx)
	if err != nil {
		t.Fatalf("ListDocuments: %v", err)
	}
	if len(docs) != 1 {
		t.Fatalf("ожидался 1 закрытый документ (draft не в списке), получено %d", len(docs))
	}
	if docs[0].ID != sid || docs[0].WarehouseCode != "SHB" || docs[0].LinesCount != 1 {
		t.Fatalf("документ: id=%s склад=%s строк=%d", docs[0].ID, docs[0].WarehouseCode, docs[0].LinesCount)
	}
}
