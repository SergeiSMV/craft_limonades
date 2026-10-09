package service_test

import (
	"context"
	"testing"

	"github.com/google/uuid"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/internal/service"
)

// Документ «Поступление» (P4-10): рождается в транзакции оприходования, строки — товарные
// (короба развёрнуты и сложены), шапка — склад, поставщик, исполнитель.

// Короб и россыпь одного товара одной партии в одной ячейке — одна строка документа.
func TestReceiptDocument_createdOnPostWithAggregatedRows(t *testing.T) {
	e := setupReceipt(t)
	ctx := context.Background()
	luID := uuid.NewString()

	res := e.applyOne(t, e.receiptOp("ffffffff-1111-4111-8111-ffffffffffff", uuid.NewString(),
		[]map[string]any{{"id": luID}},
		[]map[string]any{
			{"good_id": e.good, "production_date": "01-09-2026", "cell_id": e.cell1, "load_unit_id": luID, "qty": 12},
			{"good_id": e.good, "production_date": "01-09-2026", "cell_id": e.cell1, "qty": 3},
			{"good_id": e.good, "production_date": "02-09-2026", "qty": 1}, // другая партия, ячейка по умолчанию
		}))
	if res.Status != service.StatusAccepted {
		t.Fatalf("приёмка: %q (%s)", res.Status, res.Error)
	}

	docs := repository.NewReportDocumentRepository(e.pool)
	list, err := docs.List(ctx, model.ReportKindReceipt)
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 1 {
		t.Fatalf("документов «Поступление»: %d", len(list))
	}
	if list[0].Supplier != "Поставщик" || list[0].LinesCount != 2 || list[0].Status != model.DocStatusNew {
		t.Fatalf("строка списка: %+v", list[0])
	}

	doc, err := docs.ByID(ctx, list[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	snap := doc.Snapshot
	if snap.WarehouseCode != "SHB" || snap.Executor != "Кладовщик" || snap.Supplier != "Поставщик" {
		t.Fatalf("шапка: %+v", snap)
	}
	// Строки отсортированы по ячейке: «M1-1-1-1» раньше «С-Н-П».
	if len(snap.Rows) != 2 ||
		snap.Rows[0].CellAddress != "M1-1-1-1" || snap.Rows[0].Qty != "15" || snap.Rows[0].ProductionDate != "2026-09-01" ||
		snap.Rows[1].CellAddress != "С-Н-П" || snap.Rows[1].Qty != "1" {
		t.Fatalf("строки: %+v", snap.Rows)
	}

	// Журнал начат событием «сформирован» от имени того, кто принимал.
	events, err := service.NewDocumentService(docs).Events(ctx, doc.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 || events[0].Event != model.DocEventCreated || events[0].UserName != "Кладовщик" {
		t.Fatalf("журнал: %+v", events)
	}
}

// Прямая ручка оприходования (P4-03) тоже порождает документ: путь проводки один.
func TestReceiptDocument_directPostToo(t *testing.T) {
	e := setupReceipt(t)
	ctx := context.Background()
	id := uuid.NewString()
	if err := e.svc.Start(ctx, id, e.warehouse, "", e.user, "ТН-1", "01-10-2026"); err != nil {
		t.Fatal(err)
	}
	if _, err := e.svc.AddLine(ctx, id, e.good, "01-09-2026", "", "", decimal.NewFromInt(2)); err != nil {
		t.Fatal(err)
	}
	if _, err := e.svc.Post(ctx, id); err != nil {
		t.Fatal(err)
	}
	doc, err := repository.NewReportDocumentRepository(e.pool).BySource(ctx, model.SourceTypeReceipt, id)
	if err != nil {
		t.Fatalf("документ по прямой проводке: %v", err)
	}
	if doc.Kind != model.ReportKindReceipt || doc.Snapshot.Supplier != "" {
		t.Fatalf("документ: %+v", doc)
	}
}

// Отклонённая приёмка документа не оставляет: снимок в той же транзакции, что и проводка.
func TestReceiptDocument_notCreatedOnRejection(t *testing.T) {
	e := setupReceipt(t)
	res := e.applyOne(t, e.receiptOp("abababab-1111-4111-8111-abababababab", uuid.NewString(), nil,
		[]map[string]any{{"good_id": uuid.NewString(), "production_date": "01-09-2026", "qty": 1}}))
	if res.Status != service.StatusRejected {
		t.Fatalf("ждали отказ, получили %q", res.Status)
	}
	if n := e.countRows(t, `SELECT count(*) FROM report_documents`); n != 0 {
		t.Fatalf("документ после отказа: %d", n)
	}
}

// Фильтр по форме: «Поступление» не попадает во вкладку инвентаризации, и наоборот.
func TestReportDocuments_listFilteredByKind(t *testing.T) {
	e := setupReceipt(t)
	ctx := context.Background()
	e.applyOne(t, e.receiptOp("cdcdcdcd-1111-4111-8111-cdcdcdcdcdcd", uuid.NewString(), nil,
		[]map[string]any{{"good_id": e.good, "production_date": "01-09-2026", "qty": 1}}))

	docs := repository.NewReportDocumentRepository(e.pool)
	stock, err := docs.List(ctx, model.ReportKindStockEntry)
	if err != nil {
		t.Fatal(err)
	}
	all, err := docs.List(ctx, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(stock) != 0 || len(all) != 1 {
		t.Fatalf("фильтр по форме: инвентаризация %d, всего %d", len(stock), len(all))
	}
}
