package repository_test

import (
	"context"
	"testing"

	"github.com/google/uuid"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// Тесты ADHOC-55: номер у каждой операции и каждого документа для 1С, у каждого вида свой
// счётчик.

// Перемещение и пополнение считаются каждое своим счётчиком; документы «Движение» - своим,
// общим для формы; номер операции - в снимке и в списке документов, номер документа - в списке.
func TestOperationNumbers_movementsAndDocuments(t *testing.T) {
	mf := setupMove(t)
	ctx := context.Background()
	boxA, boxB := mf.twoBoxes(t) // фикстура уже провела перемещение 1
	m1, m2, r1 := uuid.NewString(), uuid.NewString(), uuid.NewString()
	if _, err := mf.move(t, m1, luTo(boxA, mf.cellC)); err != nil {
		t.Fatalf("перемещение 1: %v", err)
	}
	if _, err := mf.replenish(t, r1, luTo(boxB, mf.cellC)); err != nil {
		t.Fatalf("пополнение: %v", err)
	}
	if _, err := mf.move(t, m2, luTo(boxA, mf.cellB)); err != nil {
		t.Fatalf("перемещение 2: %v", err)
	}

	var numbers string
	mustScan(t, mf.pool, `SELECT string_agg(kind || number, ',' ORDER BY posted_at) FROM movements`, &numbers)
	if numbers != "move1,move2,replenish1,move3" {
		t.Errorf("номера движений: %s", numbers)
	}

	docs, err := repository.NewReportDocumentRepository(mf.pool).List(ctx, model.ReportKindMovement)
	mustNoErr(t, err)
	got := map[int64]int64{} // номер документа → номер операции
	for _, d := range docs {
		got[d.Number] = d.SourceNumber
	}
	// Документы - по порядку проведения: ДД-1 - ПМ-1, ДД-2 - ПМ-2, ДД-3 - ПП-1, ДД-4 - ПМ-3.
	if len(got) != 4 || got[1] != 1 || got[2] != 2 || got[3] != 1 || got[4] != 3 {
		t.Errorf("документы «Движение» (номер → операция): %v", got)
	}

	doc, err := repository.NewReportDocumentRepository(mf.pool).BySource(ctx, model.SourceTypeMovement, r1)
	mustNoErr(t, err)
	if doc.Snapshot.Number != 3 || doc.Snapshot.SourceNumber != 1 || doc.Snapshot.Operation != model.MovementReplenish {
		t.Errorf("снимок пополнения: документ %d, операция %s %d",
			doc.Snapshot.Number, doc.Snapshot.Operation, doc.Snapshot.SourceNumber)
	}

	// Лента перемещений и история короба называют операции номерами.
	rec, err := repository.NewMovementHistoryRepository(mf.pool).Get(ctx, m2)
	mustNoErr(t, err)
	if rec.Number != 3 {
		t.Errorf("номер в ленте: %d", rec.Number)
	}
	hist, err := repository.NewContentsRepository(mf.pool).LoadUnitHistory(ctx, boxA)
	mustNoErr(t, err)
	last := hist.Moves[len(hist.Moves)-1]
	if last.Operation != model.MovementMove || last.OperationNumber != 3 {
		t.Errorf("история короба: %s %d", last.Operation, last.OperationNumber)
	}
}

// Миграция нумерует существующие записи по порядку и продолжает счётчик с последнего номера -
// у движений и документов по виду.
func TestOperationNumbers_migrationBackfill(t *testing.T) {
	mf := setupMove(t)
	boxA, boxB := mf.twoBoxes(t)
	if _, err := mf.move(t, uuid.NewString(), luTo(boxA, mf.cellC)); err != nil {
		t.Fatal(err)
	}
	if _, err := mf.move(t, uuid.NewString(), luTo(boxB, mf.cellC)); err != nil {
		t.Fatal(err)
	}
	execMigration(t, mf.stockFixture, "000038_operation_numbers.down.sql")
	execMigration(t, mf.stockFixture, "000038_operation_numbers.up.sql")

	if _, err := mf.move(t, uuid.NewString(), luTo(boxA, mf.cellB)); err != nil {
		t.Fatalf("перемещение после миграции: %v", err)
	}
	var moves, docs, receipts, sources string
	mustScan(t, mf.pool, `SELECT string_agg(number::text, ',' ORDER BY posted_at) FROM movements`, &moves)
	mustScan(t, mf.pool, `SELECT string_agg(number::text, ',' ORDER BY created_at)
		FROM report_documents WHERE kind = 'movement'`, &docs)
	mustScan(t, mf.pool, `SELECT string_agg(number::text, ',' ORDER BY created_at) FROM receipts`, &receipts)
	if moves != "1,2,3,4" || docs != "1,2,3,4" {
		t.Errorf("после миграции: движения %s, документы %s", moves, docs)
	}
	// Старые документы получили номер своей операции в снимок.
	mustScan(t, mf.pool, `SELECT string_agg(snapshot->>'source_number', ',' ORDER BY created_at)
		FROM report_documents WHERE kind = 'movement'`, &sources)
	if sources != "1,2,3,4" {
		t.Errorf("номера операций в снимках: %s", sources)
	}
	if receipts == "" {
		t.Error("приёмки фикстуры без номера")
	}
}
