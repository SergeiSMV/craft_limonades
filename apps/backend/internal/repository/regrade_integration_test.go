package repository_test

import (
	"context"
	"errors"
	"testing"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// Тесты ADHOC-53: перепривязка ШК маркируемого товара с пересортом марок ЧЗ со склада.
// Фикстура setupCZMove: в ячейке A короб ЧЗ boxA (12 шт, из них 3 марки) и россыпь 5 марок.

// czBarcode - ШК марок фикстуры: GTIN 04600000000017 без ведущего нуля.
const czBarcode = "4600000000017"

// regradeFixture - фикстура марок с ШК, привязанным к товару фикстуры, и вторым товаром.
type regradeFixture struct {
	*czMoveFixture
	other string
	repo  *repository.BarcodeRepository
}

func setupRegrade(t *testing.T) *regradeFixture {
	t.Helper()
	cf := setupCZMove(t)
	rf := &regradeFixture{czMoveFixture: cf, repo: repository.NewBarcodeRepository(cf.pool)}
	mustScan(t, cf.pool, `INSERT INTO goods (name, uom) VALUES ('Правильный','шт') RETURNING id::text`, &rf.other)
	if err := rf.repo.Bind(context.Background(), cf.good, czBarcode, "ean13"); err != nil {
		t.Fatalf("привязать ШК марок: %v", err)
	}
	return rf
}

// stockOf - остаток товара партии (любой партии товара) в ячейке на складе по умолчанию.
func (rf *regradeFixture) stockOf(t *testing.T, good string) string {
	t.Helper()
	var q string
	mustScan(t, rf.pool, `
		SELECT COALESCE(sum(qty), 0)::int::text FROM stock
		WHERE cell_id = $1::uuid AND good_id = $2::uuid AND internal_warehouse_id = $3::uuid`,
		&q, rf.cellA, good, rf.iwh)
	return q
}

// boxOf - сколько товара в коробе boxA.
func (rf *regradeFixture) boxOf(t *testing.T, good string) string {
	t.Helper()
	var q string
	mustScan(t, rf.pool, `
		SELECT COALESCE(sum(qty), 0)::int::text FROM lu_content
		WHERE load_unit_id = $1::uuid AND good_id = $2::uuid`, &q, rf.boxA, good)
	return q
}

func (rf *regradeFixture) regrade() (model.RegradeResult, error) {
	return rf.repo.Regrade(context.Background(), model.RegradeInput{
		Barcode: czBarcode, GoodID: rf.other, UserID: rf.user,
	})
}

// ШК с марками на складе не отвязать и не привязать к другому товару; перепривязка переводит
// ШК, марки, остаток ячейки и состав короба на новый товар и заводит пересорт, который офис
// проводит документом 1С.
func TestRegrade_marksAndStockMoveToNewGood(t *testing.T) {
	rf := setupRegrade(t)
	ctx := context.Background()

	if err := rf.repo.Unbind(ctx, czBarcode); !errors.Is(err, model.ErrBarcodeHasCZStock) {
		t.Fatalf("отвязка ШК с марками на складе: %v", err)
	}
	if err := rf.repo.Bind(ctx, rf.other, "04600000000017", ""); !errors.Is(err, model.ErrBarcodeMarksOtherGood) {
		t.Fatalf("привязка GTIN марок к другому товару: %v", err)
	}
	if n, err := rf.repo.CZStockOfBarcode(ctx, czBarcode); err != nil || n != 8 {
		t.Fatalf("марок на складе: %d, %v", n, err)
	}
	stockBefore := rf.stockOf(t, rf.good)

	res, err := rf.regrade()
	if err != nil || res.Marks != 8 || res.ProblemID == "" {
		t.Fatalf("перепривязка: %+v, %v", res, err)
	}

	var bound string
	mustScan(t, rf.pool, `SELECT good_id::text FROM barcodes WHERE barcode = $1`, &bound, czBarcode)
	if bound != rf.other {
		t.Errorf("ШК остался за прежним товаром")
	}
	var onOther, linked string
	mustScan(t, rf.pool, `SELECT count(*)::text FROM cz_marks WHERE good_id = $1::uuid`, &onOther, rf.other)
	mustScan(t, rf.pool, `SELECT count(*)::text FROM cz_marks WHERE problem_id = $1::uuid`, &linked, res.ProblemID)
	if onOther != "8" || linked != "8" {
		t.Errorf("марок на новом товаре: %s, с пересортом: %s", onOther, linked)
	}
	if got := rf.stockOf(t, rf.other); got != "8" {
		t.Errorf("остаток нового товара в A: %s, ожидалось 8", got)
	}
	if before, after := stockBefore, rf.stockOf(t, rf.good); before != "17" || after != "9" {
		t.Errorf("остаток прежнего товара в A: %s → %s, ожидалось 17 → 9", before, after)
	}
	if x, y := rf.boxOf(t, rf.good), rf.boxOf(t, rf.other); x != "9" || y != "3" {
		t.Errorf("состав короба: прежний %s, новый %s - ожидалось 9 и 3", x, y)
	}
	if _, err := rf.regrade(); !errors.Is(err, model.ErrRegradeSameGood) {
		t.Errorf("повтор перепривязки: %v", err)
	}

	problems := repository.NewProblemRepository(rf.pool)
	list, err := problems.List(ctx, model.ProblemFilter{Status: model.ProblemStatusOpen})
	if err != nil || len(list) != 1 {
		t.Fatalf("открытые проблемы: %d, %v", len(list), err)
	}
	p := list[0]
	if p.Reason != model.ProblemReasonRegrade || p.FromGoodName != "Товар" || p.Barcode != czBarcode ||
		p.CellAddress != "" || p.FromWarehouse != "" || len(p.Marks) != 8 || len(p.Items) != 2 ||
		p.Comment != "Перепривязка GTIN 04600000000017" {
		t.Fatalf("пересорт в списке: %+v", p)
	}
	for _, it := range p.Items {
		if it.GoodName != "Правильный" || it.CellAddress != "A" {
			t.Errorf("строка пересорта: %+v", it)
		}
	}

	if err := problems.Resolve(ctx, model.ResolveProblemInput{
		ProblemID: p.ID, Decision: model.ProblemDecisionWriteOff, DocNumber: "1", DocDate: "2026-10-28",
		ResolvedBy: rf.user,
	}); !errors.Is(err, model.ErrDecisionNotAllowed) {
		t.Errorf("списание пересорта: %v", err)
	}
	if err := problems.Resolve(ctx, model.ResolveProblemInput{
		ProblemID: p.ID, Decision: model.ProblemDecisionRegrade, DocNumber: "ПС-7", DocDate: "2026-10-28",
		ResolvedBy: rf.user,
	}); err != nil {
		t.Fatalf("провести пересорт: %v", err)
	}
	if got := rf.stockOf(t, rf.other); got != "8" {
		t.Errorf("решение пересорта двинуло остаток: %s", got)
	}
}

// Отказ без изменений: марки в открытой проблеме склада, ячейка марок на пересчёте.
func TestRegrade_refusals(t *testing.T) {
	t.Run("марка в открытой проблеме", func(t *testing.T) {
		rf := setupRegrade(t)
		rf.openProblem(t, rf.iwhByCode(t, "ISOLATOR"), model.ProblemReasonForeignMark,
			rf.markProblem(rf.cellA, "", czLoose[0]))
		if _, err := rf.regrade(); !errors.Is(err, model.ErrRegradeOpenProblem) {
			t.Fatalf("перепривязка: %v", err)
		}
		var bound string
		mustScan(t, rf.pool, `SELECT good_id::text FROM barcodes WHERE barcode = $1`, &bound, czBarcode)
		if bound != rf.good {
			t.Error("отказ перепривязки сменил ШК")
		}
	})

	t.Run("ячейка на пересчёте", func(t *testing.T) {
		rf := setupRegrade(t)
		var st string
		mustScan(t, rf.pool, `INSERT INTO stocktakes (warehouse_id, scope_kind, created_by)
			VALUES ($1::uuid, 'cells', $2::uuid) RETURNING id::text`, &st, rf.wh, rf.user)
		if _, err := rf.pool.Exec(context.Background(), `
			INSERT INTO stocktake_cells (stocktake_id, cell_id, status, taken_by, taken_at, started_at)
			VALUES ($1::uuid, $2::uuid, 'counting', $3::uuid, now(), now())`, st, rf.cellA, rf.user); err != nil {
			t.Fatalf("ячейка на пересчёте: %v", err)
		}
		if _, err := rf.regrade(); !errors.Is(err, model.ErrRegradeCellCounting) {
			t.Fatalf("перепривязка: %v", err)
		}
		if got := rf.stockOf(t, rf.other); got != "0" {
			t.Errorf("отказ перепривязки двинул остаток: %s", got)
		}
	})
}
