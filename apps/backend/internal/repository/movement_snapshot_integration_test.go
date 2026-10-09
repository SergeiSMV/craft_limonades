package repository_test

import (
	"context"
	"testing"

	"github.com/google/uuid"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// Тесты P5-04: «Движение» рождается в транзакции размещения.

// Сеанс размещения публикует «Движение»: основание — задание и приёмка с накладной, короба
// разложены по составу и сложены с россыпью той же партии и той же пары ячеек.
func TestPutaway_publishesMovementDocument(t *testing.T) {
	pf := setupPutaway(t)
	lu1 := newLU(t, pf.stockFixture, model.LoadUnitBox)
	lu2 := newLU(t, pf.stockFixture, model.LoadUnitBox)
	task := pf.receive(t, []string{lu1, lu2}, 5) // в A: два короба по 12 и 5 россыпью

	putaway := uuid.NewString()
	if _, err := pf.submit(t, task, putaway,
		boxTo(lu1, pf.cellB), looseTo(pf.good, 5, pf.cellB), boxTo(lu2, pf.cellB)); err != nil {
		t.Fatalf("размещение: %v", err)
	}

	docs := repository.NewReportDocumentRepository(pf.pool)
	doc, err := docs.BySource(context.Background(), model.SourceTypePutaway, putaway)
	if err != nil {
		t.Fatalf("документ по сеансу: %v", err)
	}
	s := doc.Snapshot
	var taskNumber int64
	if err := pf.pool.QueryRow(context.Background(),
		`SELECT number FROM warehouse_tasks WHERE id = $1::uuid`, task).Scan(&taskNumber); err != nil {
		t.Fatal(err)
	}
	if doc.Kind != model.ReportKindMovement || s.Operation != model.MovementOperationPutaway {
		t.Errorf("форма %q, операция %q", doc.Kind, s.Operation)
	}
	if s.TaskNumber != taskNumber || s.DocNumber != testDoc.Number || s.DocDate != "2026-10-01" ||
		s.Executor != "Кладовщик" || s.WarehouseCode != "WH1" {
		t.Errorf("шапка: %+v", s)
	}
	// 12 + 5 + 12 из A в B — одна строка: 1С короба не различает.
	if len(s.Rows) != 1 {
		t.Fatalf("строк %d, ожидалась одна: %+v", len(s.Rows), s.Rows)
	}
	if r := s.Rows[0]; r.FromCellAddress != "A" || r.CellAddress != "B" || r.Qty != "29" {
		t.Errorf("строка: %+v", r)
	}

	// Документ виден в списке «Движения» с основанием и попадает в журнал как сформированный.
	list, err := docs.List(context.Background(), model.ReportKindMovement)
	mustNoErr(t, err)
	if len(list) != 1 || list[0].TaskNumber != taskNumber || list[0].Operation != model.MovementOperationPutaway ||
		list[0].LinesCount != 1 {
		t.Errorf("список: %+v", list)
	}
	events, err := docs.Events(context.Background(), doc.ID)
	mustNoErr(t, err)
	if len(events) != 1 || events[0].Event != model.DocEventCreated || events[0].UserName != "Кладовщик" {
		t.Errorf("журнал: %+v", events)
	}
}

// Каждый сеанс — свой документ; отклонённый сеанс документа не оставляет.
func TestPutaway_movementDocumentPerSession(t *testing.T) {
	pf := setupPutaway(t)
	lu := newLU(t, pf.stockFixture, model.LoadUnitBox)
	task := pf.receive(t, []string{lu}, 5)

	rejected := uuid.NewString()
	if _, err := pf.submit(t, task, rejected, boxTo(lu, pf.cellB), looseTo(pf.good, 6, pf.cellB)); err == nil {
		t.Fatal("сеанс сверх задания проведён")
	}
	mustNoErr(t, func() error {
		_, err := pf.submit(t, task, uuid.NewString(), boxTo(lu, pf.cellB))
		return err
	}())
	mustNoErr(t, func() error {
		_, err := pf.submit(t, task, uuid.NewString(), looseTo(pf.good, 5, pf.cellB))
		return err
	}())

	var n int
	mustScanInt(t, pf, `SELECT count(*) FROM report_documents WHERE kind = 'movement'`, &n)
	if n != 2 {
		t.Errorf("документов «Движение» %d, ожидалось 2 (по сеансу)", n)
	}
	mustScanInt(t, pf, `SELECT count(*) FROM report_documents WHERE source_id = $1::uuid`, &n, rejected)
	if n != 0 {
		t.Error("отклонённый сеанс оставил документ")
	}
}
