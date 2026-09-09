package service_test

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/shopspring/decimal"
	"github.com/xuri/excelize/v2"

	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/internal/service"
	"craftwms/internal/testutil"
)

// Рабочий список документов оператора (P3-02): состав списка, содержимое файла, статусы.
// Пришёл на смену тесту сервиса отчёта по сессии — адресация сменилась с сессии на документ.
func TestDocuments(t *testing.T) {
	pool := testutil.StartPostgres(t)
	ctx := context.Background()
	seRepo := repository.NewStockEntryRepository(pool)
	docRepo := repository.NewReportDocumentRepository(pool)
	svc := service.NewDocumentService(docRepo)

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

	// Закрытая сессия: старт → checkpoint → финал. Документ рождается в финале (P3-01).
	sid, err := seRepo.Create(ctx, wh, user)
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if err := seRepo.Checkpoint(ctx, sid, cell, []repository.StockEntryLineInput{
		{GoodID: good, ProductionDate: "2026-01-15", Qty: decimal.RequireFromString("10.5")},
	}, nil); err != nil {
		t.Fatalf("Checkpoint: %v", err)
	}
	if _, err := seRepo.Finalize(ctx, sid); err != nil {
		t.Fatalf("Finalize: %v", err)
	}
	// Ещё одна сессия остаётся в работе — в список документов она попасть не должна.
	draft, err := seRepo.Create(ctx, wh, user)
	if err != nil {
		t.Fatalf("Create draft: %v", err)
	}
	if _, err := docRepo.BySource(ctx, model.SourceTypeStockEntrySession, draft); !errors.Is(err, repository.ErrDocumentNotFound) {
		t.Errorf("незавершённая сессия: ожидалась ErrDocumentNotFound, получено %v", err)
	}

	// --- список ---
	docs, err := svc.List(ctx)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(docs) != 1 {
		t.Fatalf("ожидался 1 документ (незавершённая сессия не в списке), получено %d", len(docs))
	}
	doc := docs[0]
	if doc.WarehouseCode != "SHB" || doc.LinesCount != 1 || doc.Kind != model.ReportKindStockEntry {
		t.Fatalf("документ: склад=%s строк=%d форма=%s", doc.WarehouseCode, doc.LinesCount, doc.Kind)
	}
	if doc.Status != model.DocStatusNew || doc.DownloadedAt != nil || doc.DoneAt != nil {
		t.Errorf("свежий документ: статус=%s скачан=%v выполнен=%v", doc.Status, doc.DownloadedAt, doc.DoneAt)
	}

	// --- файл ---
	data, filename, err := svc.File(ctx, doc.ID, user)
	if err != nil {
		t.Fatalf("File: %v", err)
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
	want := []string{"Шабулина", "M1-1-1-1", "16121", "Кальмар", "15.01.2026", "10.5"}
	for i, v := range want {
		if rows[1][i] != v {
			t.Errorf("строка [%d]: ожидалось %q, получено %q", i, v, rows[1][i])
		}
	}

	// --- статус после скачивания ---
	docs, _ = svc.List(ctx)
	if docs[0].Status != model.DocStatusDownloaded || docs[0].DownloadedAt == nil {
		t.Errorf("после скачивания: статус=%s скачан=%v", docs[0].Status, docs[0].DownloadedAt)
	}
	firstDownload := *docs[0].DownloadedAt

	// --- «Выполнено» ---
	if err := svc.MarkDone(ctx, doc.ID, user); err != nil {
		t.Fatalf("MarkDone: %v", err)
	}
	docs, _ = svc.List(ctx)
	if docs[0].Status != model.DocStatusDone || docs[0].DoneAt == nil {
		t.Fatalf("после отметки: статус=%s выполнен=%v", docs[0].Status, docs[0].DoneAt)
	}
	doneAt := *docs[0].DoneAt

	// Повторное скачивание выполненного НЕ возвращает документ в работу и не двигает отметки:
	// оператор мог открыть файл для сверки, и откатывать «занесено в 1С» по такому поводу нельзя.
	if _, _, err := svc.File(ctx, doc.ID, user); err != nil {
		t.Fatalf("повторное скачивание: %v", err)
	}
	docs, _ = svc.List(ctx)
	if docs[0].Status != model.DocStatusDone {
		t.Errorf("повторное скачивание сбросило статус: %s", docs[0].Status)
	}
	if !docs[0].DownloadedAt.Equal(firstDownload) {
		t.Errorf("повтор переписал время первого скачивания: %v → %v", firstDownload, *docs[0].DownloadedAt)
	}

	// Повторная отметка идемпотентна: время не сдвигается.
	if err := svc.MarkDone(ctx, doc.ID, user); err != nil {
		t.Fatalf("повторный MarkDone: %v", err)
	}
	docs, _ = svc.List(ctx)
	if !docs[0].DoneAt.Equal(doneAt) {
		t.Errorf("повторная отметка сдвинула время: %v → %v", doneAt, *docs[0].DoneAt)
	}

	// --- границы ---
	if _, _, err := svc.File(ctx, "00000000-0000-0000-0000-0000000000ff", user); !errors.Is(err, repository.ErrDocumentNotFound) {
		t.Errorf("нет документа: ожидалась ErrDocumentNotFound, получено %v", err)
	}
	if err := svc.MarkDone(ctx, "00000000-0000-0000-0000-0000000000ff", user); !errors.Is(err, repository.ErrDocumentNotFound) {
		t.Errorf("отметка несуществующего: ожидалась ErrDocumentNotFound, получено %v", err)
	}
	if err := svc.MarkDone(ctx, "", user); !errors.Is(err, service.ErrEmptyDocumentID) {
		t.Errorf("пустой id: ожидалась ErrEmptyDocumentID, получено %v", err)
	}

	// --- журнал (P3-03) ---
	// К этому моменту документ: сформирован, скачан дважды, отмечен выполненным дважды.
	events, err := svc.Events(ctx, doc.ID)
	if err != nil {
		t.Fatalf("Events: %v", err)
	}
	var seq []string
	for _, e := range events {
		seq = append(seq, e.Event)
	}
	wantEvents := []string{
		model.DocEventCreated,
		model.DocEventDownloaded,
		model.DocEventDone,
		model.DocEventDownloaded, // повторное скачивание — отдельная запись, статус при этом не менялся
		model.DocEventDone,
	}
	if len(seq) != len(wantEvents) {
		t.Fatalf("журнал: %v, ожидалось %v", seq, wantEvents)
	}
	for i := range wantEvents {
		if seq[i] != wantEvents[i] {
			t.Errorf("журнал[%d]: %q, ожидалось %q", i, seq[i], wantEvents[i])
		}
	}
	// Автор виден по имени: журнал хранит ссылку на пользователя, а не копию ФИО.
	for _, e := range events {
		if e.UserName != "Тест" {
			t.Errorf("событие %q: автор %q, ожидался «Тест»", e.Event, e.UserName)
		}
	}
	if _, err := svc.Events(ctx, "00000000-0000-0000-0000-0000000000ff"); !errors.Is(err, repository.ErrDocumentNotFound) {
		t.Errorf("журнал несуществующего: ожидалась ErrDocumentNotFound, получено %v", err)
	}
}
