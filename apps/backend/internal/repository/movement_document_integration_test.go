package repository_test

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// Тесты P6-07: «Движение» по документу перемещения рождается в транзакции проведения.
// Фикстура setupMove — из movement_integration_test.go.

// movementDoc читает документ «Движение» по документу движения.
func (mf *moveFixture) movementDoc(t *testing.T, movementID string) (model.ReportDocument, error) {
	t.Helper()
	return repository.NewReportDocumentRepository(mf.pool).BySource(context.Background(), model.SourceTypeMovement, movementID)
}

// Короб раскладывается по составу на момент своего переноса: доложенное или взятое из него
// дальше в том же документе не меняет его строку. Движение внутри ячейки в документ не
// попадает, перемещение россыпи в другую ячейку — попадает.
func TestMove_publishesMovementDocument(t *testing.T) {
	mf := setupMove(t)
	ctx := context.Background()
	lu := newLU(t, mf.stockFixture, model.LoadUnitBox)
	mf.receive(t, []string{lu}, 5) // A: короб 12 + россыпь 5

	mv := uuid.NewString()
	if _, err := mf.move(t, mv,
		luTo(lu, mf.cellB),                          // короб A → B: 12
		mf.goodsLine(4, "", lu, mf.cellB, ""),       // из короба в россыпь той же B: «нулевая»
		mf.goodsLine(2, mf.cellA, "", mf.cellC, ""), // россыпь A → C: 2
	); err != nil {
		t.Fatalf("перемещение: %v", err)
	}

	doc, err := mf.movementDoc(t, mv)
	if err != nil {
		t.Fatalf("документ по перемещению: %v", err)
	}
	s := doc.Snapshot
	if doc.Kind != model.ReportKindMovement || s.Operation != model.MovementOperationMove {
		t.Errorf("форма %q, операция %q", doc.Kind, s.Operation)
	}
	if s.Executor != "Кладовщик" || s.WarehouseCode != "WH1" || s.TaskNumber != 0 || s.Supplier != "" {
		t.Errorf("шапка: %+v", s)
	}
	// Короб — 12, как переехал, а не 8, что в нём осталось к концу документа.
	got := ""
	for _, r := range s.Rows {
		got += r.FromCellAddress + ">" + r.CellAddress + ":" + r.Qty + " "
	}
	if got != "A>B:12 A>C:2 " {
		t.Errorf("строки: %q, ожидалось «A>B:12 A>C:2»", got)
	}

	list, err := repository.NewReportDocumentRepository(mf.pool).List(ctx, model.ReportKindMovement)
	mustNoErr(t, err)
	if len(list) != 1 || list[0].Operation != model.MovementOperationMove || list[0].Executor != "Кладовщик" ||
		list[0].LinesCount != 2 {
		t.Errorf("список: %+v", list)
	}
	events, err := repository.NewReportDocumentRepository(mf.pool).Events(ctx, doc.ID)
	mustNoErr(t, err)
	if len(events) != 1 || events[0].Event != model.DocEventCreated || events[0].UserName != "Кладовщик" {
		t.Errorf("журнал: %+v", events)
	}
}

// Документ, где всё движение — внутри одной ячейки, проводится, но не публикуется: для 1С
// ничего не переехало. Отклонённый документ не оставляет и «Движения».
func TestMove_zeroMovementNotPublished(t *testing.T) {
	mf := setupMove(t)
	lu := newLU(t, mf.stockFixture, model.LoadUnitBox)
	mf.receive(t, []string{lu}, 5)

	inside := uuid.NewString()
	if _, err := mf.move(t, inside,
		mf.goodsLine(3, "", lu, mf.cellA, ""),
		mf.goodsLine(1, mf.cellA, "", "", lu),
	); err != nil {
		t.Fatalf("движение внутри ячейки: %v", err)
	}
	if _, err := mf.movementDoc(t, inside); !errors.Is(err, repository.ErrDocumentNotFound) {
		t.Errorf("документ по движению внутри ячейки: %v, ожидалось «нет»", err)
	}
	if mf.luQty(t, lu) != "10.000" {
		t.Errorf("состав короба %s, ожидалось 10: движение проведено", mf.luQty(t, lu))
	}

	rejected := uuid.NewString()
	if _, err := mf.move(t, rejected, luTo(lu, mf.cellB), mf.goodsLine(99, mf.cellA, "", mf.cellC, "")); err == nil {
		t.Fatal("документ сверх остатка проведён")
	}
	var n string
	mustScan(t, mf.pool, `SELECT count(*)::text FROM report_documents WHERE kind = 'movement'`, &n)
	if n != "0" {
		t.Errorf("документов «Движение» %s, ожидалось 0", n)
	}
}

// Пополнение заморожено на ТСД, но сервер его проводит — и публикует с операцией пополнения.
func TestReplenish_publishesMovementDocument(t *testing.T) {
	mf := setupMove(t)
	lu := newLU(t, mf.stockFixture, model.LoadUnitBox)
	mf.receive(t, []string{lu}, 0)

	mv := uuid.NewString()
	if _, err := mf.replenish(t, mv, luTo(lu, mf.cellB)); err != nil {
		t.Fatalf("пополнение: %v", err)
	}
	doc, err := mf.movementDoc(t, mv)
	if err != nil {
		t.Fatalf("документ по пополнению: %v", err)
	}
	if doc.Snapshot.Operation != model.MovementOperationReplenish || len(doc.Snapshot.Rows) != 1 {
		t.Errorf("операция %q, строк %d", doc.Snapshot.Operation, len(doc.Snapshot.Rows))
	}
}
