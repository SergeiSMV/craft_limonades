package repository_test

import (
	"context"
	"sort"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// Тесты ADHOC-55: марки ЧЗ в документах 1С. Маркируемый товар в документе - строка на марку
// с количеством 1; что марками не покрыто - общей строкой, как раньше.

// docRows - строки документа операции: «марка=количество» (без марки - «-=количество»),
// отсортированы - порядок строк проверяют тесты шаблонов.
func docRows(t *testing.T, pool *pgxpool.Pool, sourceType, sourceID string) []string {
	t.Helper()
	doc, err := repository.NewReportDocumentRepository(pool).BySource(context.Background(), sourceType, sourceID)
	mustNoErr(t, err)
	out := make([]string, 0, len(doc.Snapshot.Rows))
	for _, r := range doc.Snapshot.Rows {
		mark, qty := r.Mark, r.Qty
		if mark == "" {
			mark = "-"
		}
		if qty == "" {
			qty = r.Expected + "/" + r.Fact
		}
		if q, err := decimal.NewFromString(qty); err == nil {
			qty = q.String()
		}
		out = append(out, mark+"="+qty)
	}
	sort.Strings(out)
	return out
}

func wantRows(t *testing.T, what string, got []string, want ...string) {
	t.Helper()
	sort.Strings(want)
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Errorf("%s: строки %v, ожидались %v", what, got, want)
	}
}

// Перемещение: россыпь марками и короб ЧЗ целиком - у каждой марки своя строка; марки
// россыпи хранятся в строке документа движения.
func TestDocumentMarks_movement(t *testing.T) {
	cf := setupCZMove(t)
	id := uuid.NewString()
	if _, err := cf.move(t, id,
		cf.markLine(cf.cellA, "", cf.cellC, "", czLoose[1], czLoose[0]),
		luTo(cf.boxA, cf.cellB),
	); err != nil {
		t.Fatalf("перемещение: %v", err)
	}
	wantRows(t, "перемещение", docRows(t, cf.pool, model.SourceTypeMovement, id),
		czLoose[0]+"=1", czLoose[1]+"=1", czG1+"=1", czG2+"=1", czB1+"=1", "-=9")
	var stored string
	mustScan(t, cf.pool, `SELECT array_to_string(marks, ',') FROM movement_lines
		WHERE movement_id = $1::uuid AND good_id IS NOT NULL`, &stored, id)
	if stored != czLoose[1]+","+czLoose[0] {
		t.Errorf("марки строки движения: %q", stored)
	}
}

// Приёмка и размещение россыпью: марки строки приёмки - в «Поступлении», марки размещённой
// россыпи - в «Движении».
func TestDocumentMarks_receiptAndPutaway(t *testing.T) {
	pf := setupPutaway(t)
	ctx := context.Background()
	repo := repository.NewReceiptRepository(pf.pool)
	receipt := uuid.NewString()
	mustNoErr(t, repo.Create(ctx, receipt, pf.wh, "", pf.user, testDoc))
	ln := model.ReceiptLineInput{
		GoodID: pf.good, ProductionDate: "2026-01-01", CellID: pf.cellA, Qty: decimal.NewFromInt(4),
	}
	for _, cis := range czLoose[:3] {
		ln.Marks = append(ln.Marks, model.ReceiptMark{CIS: cis})
	}
	mustNoErr(t, repo.AddLine(ctx, receipt, ln))
	if _, err := repo.Post(ctx, receipt); err != nil {
		t.Fatalf("оприходовать: %v", err)
	}
	wantRows(t, "поступление", docRows(t, pf.pool, model.SourceTypeReceipt, receipt),
		czLoose[0]+"=1", czLoose[1]+"=1", czLoose[2]+"=1", "-=1")

	// Марки на складе для размещения: приёмка через репозиторий их не заводит (это делает
	// проводка ЧЗ из очереди), поэтому кладём их сами.
	if _, err := pf.pool.Exec(ctx, `UPDATE goods SET cz_marked = true WHERE id = $1::uuid`, pf.good); err != nil {
		t.Fatal(err)
	}
	for _, cis := range czLoose[:2] {
		if _, err := pf.pool.Exec(ctx, `
			INSERT INTO cz_marks (cis, good_id, batch_id, cell_id, internal_warehouse_id)
			VALUES ($1, $2::uuid, $3::uuid, $4::uuid, $5::uuid)`,
			cis, pf.good, pf.batch, pf.cellA, pf.iwh); err != nil {
			t.Fatal(err)
		}
	}
	var task string
	mustScan(t, pf.pool, `SELECT id::text FROM warehouse_tasks WHERE receipt_id = $1::uuid`, &task, receipt)
	put := looseTo(pf.good, 2, pf.cellB)
	put.Marks = czLoose[:2]
	putaway := uuid.NewString()
	if _, err := pf.submit(t, task, putaway, put); err != nil {
		t.Fatalf("размещение марками: %v", err)
	}
	wantRows(t, "размещение", docRows(t, pf.pool, model.SourceTypePutaway, putaway),
		czLoose[0]+"=1", czLoose[1]+"=1")
}

// Ввод остатков: марки короба ЧЗ и россыпи - строкой на марку.
func TestDocumentMarks_stockEntry(t *testing.T) {
	ef := setupEntry(t)
	box := uuid.NewString()
	in := repository.StockEntryCellInput{
		CellID:    ef.cellC,
		LoadUnits: []repository.LoadUnitInput{{ID: box, Kind: model.LoadUnitBox, CZCode: czBox}},
		Lines: []repository.StockEntryLineInput{
			entryLine(ef.good, 2, box, czG1, czB1),
			entryLine(ef.good, 1, "", czLoose[0]),
		},
	}
	if err := ef.checkpoint(t, in); err != nil {
		t.Fatalf("checkpoint: %v", err)
	}
	if _, err := ef.repo.Finalize(context.Background(), ef.session); err != nil {
		t.Fatalf("финал: %v", err)
	}
	wantRows(t, "ввод остатков", docRows(t, ef.pool, model.SourceTypeStockEntrySession, ef.session),
		czG1+"=1", czB1+"=1", czLoose[0]+"=1")
}

// Инвентаризация: марка найдена - 1/1, не найдена - 1/0, найдена сверх снимка - 0/1.
func TestDocumentMarks_stocktake(t *testing.T) {
	fx := setupStocktake(t)
	const m1, m2, m3 = "0104600000000017215L1", "0104600000000017215L2", "0104600000000017215L3"
	fx.put(t, fx.cellB, fx.good2, fx.batch2, fx.iwh, 2)
	fx.mark(t, fx.cellB, m1)
	fx.mark(t, fx.cellB, m2)
	fx.put(t, fx.cellC, fx.good2, fx.batch2, fx.iwh, 1)
	fx.mark(t, fx.cellC, m3)
	st, cells := fx.counting(t, fx.cellB)
	if _, err := fx.submit(cells["B"], nil, fact(fx.good2, "2026-02-01", "", 2, m1, m3)); err != nil {
		t.Fatalf("подсчёт: %v", err)
	}
	if _, err := fx.repo.Close(context.Background(), st.ID, fx.user, true); err != nil {
		t.Fatalf("закрыть: %v", err)
	}
	wantRows(t, "инвентаризация", docRows(t, fx.pool, model.SourceTypeStocktake, st.ID),
		m1+"=1/1", m2+"=1/0", m3+"=0/1")
}
