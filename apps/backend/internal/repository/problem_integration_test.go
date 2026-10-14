package repository_test

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// Тесты P6-07-1: пометка браком — перевод на другой внутренний склад в той же ячейке, без
// потери количества; помеченное перемещается со своей меткой. Фикстура setupMove — из
// movement_integration_test.go (A — ячейка хранения, R — ячейка приёмки).

// iwhByCode — id внутреннего склада по коду справочника.
func (mf *moveFixture) iwhByCode(t *testing.T, code string) string {
	t.Helper()
	var id string
	mustScan(t, mf.pool, `SELECT id::text FROM internal_warehouses WHERE code = $1`, &id, code)
	return id
}

// qtyIn — остаток партии batch товара фикстуры в ячейке на складе iwh.
func (mf *moveFixture) qtyIn(t *testing.T, cell, iwh string) string {
	t.Helper()
	q, err := repository.NewStockRepository(mf.pool).GetQty(context.Background(), model.StockKey{
		CellID: cell, GoodID: mf.good, BatchID: mf.batch, InternalWarehouseID: iwh,
	})
	mustNoErr(t, err)
	return q.String()
}

// problem фиксирует проблему с причиной «бой» на складе назначения to.
func (mf *moveFixture) problem(t *testing.T, to string, in repository.ProblemSubmitInput) error {
	t.Helper()
	in.ProblemID, in.WarehouseID, in.CreatedBy = uuid.NewString(), mf.wh, mf.user
	in.ToInternalWarehouseID = to
	if in.Reason == "" {
		in.Reason = model.ProblemReasonBreakage
	}
	return repository.ProblemSubmitForTest(context.Background(), mf.pool, in)
}

// goodsProblem — товар фикстуры партии 01.01 из россыпи ячейки или из короба.
func (mf *moveFixture) goodsProblem(qty int64, cell, fromLU string) repository.ProblemSubmitInput {
	return repository.ProblemSubmitInput{
		GoodID: mf.good, ProductionDate: "2026-01-01", Qty: decimal.NewFromInt(qty),
		CellID: cell, FromLoadUnitID: fromLU,
	}
}

// Россыпь в брак: количество в ячейке то же, «Основной» уменьшился на помеченное. Брак
// перемещается своей меткой, «Основного» в россыпи осталось ровно столько, сколько не помечено.
func TestProblem_looseToDefectAndMove(t *testing.T) {
	mf := setupMove(t)
	defect := mf.iwhByCode(t, "DEFECT")
	lu := newLU(t, mf.stockFixture, model.LoadUnitBox)
	mf.receive(t, []string{lu}, 5) // A: короб 12 + россыпь 5

	if err := mf.problem(t, defect, mf.goodsProblem(2, mf.cellA, "")); err != nil {
		t.Fatalf("россыпь в брак: %v", err)
	}
	if main, def := mf.qtyIn(t, mf.cellA, mf.iwh), mf.qtyIn(t, mf.cellA, defect); main != "15" || def != "2" {
		t.Errorf("A: основной %s брак %s, ожидалось 15 и 2", main, def)
	}
	var rec string
	mustScan(t, mf.pool, `SELECT reason || ' ' || qty::text || ' ' || status FROM warehouse_problems
		WHERE from_internal_warehouse_id = $1::uuid AND to_internal_warehouse_id = $2::uuid`, &rec, mf.iwh, defect)
	if rec != "breakage 2.000 open" {
		t.Errorf("запись проблемы: %q", rec)
	}

	// «Основной» россыпи — 3: короб основной, 2 помечены.
	if _, err := mf.move(t, uuid.NewString(), mf.goodsLine(4, mf.cellA, "", mf.cellC, "")); !errors.Is(err, repository.ErrGoodsShort) {
		t.Errorf("основной россыпи больше, чем есть: %v", err)
	}
	defLine := mf.goodsLine(2, mf.cellA, "", mf.cellC, "")
	defLine.InternalWarehouseID = defect
	if _, err := mf.move(t, uuid.NewString(), defLine); err != nil {
		t.Fatalf("перемещение брака: %v", err)
	}
	if def, main := mf.qtyIn(t, mf.cellC, defect), mf.qtyIn(t, mf.cellC, mf.iwh); def != "2" || main != "0" {
		t.Errorf("C: брак %s основной %s, ожидалось 2 и 0", def, main)
	}
}

// Короб целиком в брак: короб и его остаток меняют склад, россыпь «Основного» рядом не
// задета; короб переезжает браком; основной товар в бракованный короб не кладётся.
func TestProblem_wholeBox(t *testing.T) {
	mf := setupMove(t)
	defect := mf.iwhByCode(t, "DEFECT")
	lu := newLU(t, mf.stockFixture, model.LoadUnitBox)
	mf.receive(t, []string{lu}, 5)

	if err := mf.problem(t, defect, repository.ProblemSubmitInput{LoadUnitID: lu}); err != nil {
		t.Fatalf("короб в брак: %v", err)
	}
	if main, def := mf.qtyIn(t, mf.cellA, mf.iwh), mf.qtyIn(t, mf.cellA, defect); main != "5" || def != "12" {
		t.Errorf("A: основной %s брак %s, ожидалось 5 и 12", main, def)
	}
	// Снимок ТСД видит то же: россыпь «Основного» 5, россыпи брака нет (весь брак в коробе),
	// короб — со своим складом.
	cell, err := repository.NewContentsRepository(mf.pool).CellContents(context.Background(), mf.cellA)
	mustNoErr(t, err)
	if len(cell.Loose) != 1 || cell.Loose[0].InternalWarehouseID != mf.iwh || cell.Loose[0].Qty.String() != "5" ||
		len(cell.LoadUnits) != 1 || cell.LoadUnits[0].InternalWarehouseID != defect {
		t.Errorf("содержимое A: %+v", cell)
	}
	// Россыпь «Основного» — все 5: бракованный короб вычитается из строки брака.
	if _, err := mf.move(t, uuid.NewString(), mf.goodsLine(5, mf.cellA, "", mf.cellC, "")); err != nil {
		t.Fatalf("основная россыпь рядом с бракованным коробом: %v", err)
	}
	if _, err := mf.move(t, uuid.NewString(), luTo(lu, mf.cellB)); err != nil {
		t.Fatalf("перенос бракованного короба: %v", err)
	}
	if def, main := mf.qtyIn(t, mf.cellB, defect), mf.qtyIn(t, mf.cellB, mf.iwh); def != "12" || main != "0" {
		t.Errorf("B: брак %s основной %s, ожидалось 12 и 0", def, main)
	}
	if _, err := mf.move(t, uuid.NewString(), mf.goodsLine(1, mf.cellC, "", "", lu)); !errors.Is(err, repository.ErrWarehouseMismatch) {
		t.Errorf("основной товар в бракованный короб: %v", err)
	}
}

// Часть короба в брак: товар вынимается в россыпь брака той же ячейки, короб остаётся
// основным; основная россыпь рядом не меняется.
func TestProblem_partOfBox(t *testing.T) {
	mf := setupMove(t)
	defect := mf.iwhByCode(t, "DEFECT")
	lu := newLU(t, mf.stockFixture, model.LoadUnitBox)
	mf.receive(t, []string{lu}, 5)

	if err := mf.problem(t, defect, mf.goodsProblem(2, "", lu)); err != nil {
		t.Fatalf("часть короба в брак: %v", err)
	}
	if box, main, def := mf.luQty(t, lu), mf.qtyIn(t, mf.cellA, mf.iwh), mf.qtyIn(t, mf.cellA, defect); box != "10.000" || main != "15" || def != "2" {
		t.Errorf("короб %s, A основной %s брак %s; ожидалось 10, 15, 2", box, main, def)
	}
	if _, err := mf.move(t, uuid.NewString(), mf.goodsLine(5, mf.cellA, "", mf.cellC, "")); err != nil {
		t.Errorf("основная россыпь не изменилась: %v", err)
	}
}

// Отказы по существу — и ни один не сдвигает остаток.
func TestProblem_rejections(t *testing.T) {
	mf := setupMove(t)
	ctx := context.Background()
	defect := mf.iwhByCode(t, "DEFECT")
	lu := newLU(t, mf.stockFixture, model.LoadUnitBox)
	mf.receive(t, []string{lu}, 5)

	var hidden string
	mustScan(t, mf.pool, `INSERT INTO internal_warehouses (code, name, is_active) VALUES ('OLD','Старый',false)
		RETURNING id::text`, &hidden)
	other := mf.goodsProblem(1, mf.cellA, "")
	other.Reason = "лень"

	cases := []struct {
		name string
		to   string
		in   repository.ProblemSubmitInput
		want error
	}{
		{"на тот же склад", mf.iwh, mf.goodsProblem(1, mf.cellA, ""), repository.ErrSameInternalWarehouse},
		{"склад скрыт", hidden, mf.goodsProblem(1, mf.cellA, ""), repository.ErrUnknownInternalWarehouse},
		{"склада нет", uuid.NewString(), mf.goodsProblem(1, mf.cellA, ""), repository.ErrUnknownInternalWarehouse},
		{"причины нет", defect, other, repository.ErrUnknownReason},
		{"россыпи меньше", defect, mf.goodsProblem(6, mf.cellA, ""), repository.ErrGoodsShort},
		{"из короба больше состава", defect, mf.goodsProblem(13, "", lu), repository.ErrGoodsShort},
		{"ячейка приёмки", defect, mf.goodsProblem(1, mf.cellR, ""), repository.ErrReceivingCell},
		{"ни короба, ни товара", defect, repository.ProblemSubmitInput{}, repository.ErrEmptyProblem},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if err := mf.problem(t, tc.to, tc.in); !errors.Is(err, tc.want) {
				t.Errorf("получено %v, ожидалась %v", err, tc.want)
			}
		})
	}

	// Повтор той же проблемы упирается в первичный ключ.
	in := mf.goodsProblem(1, mf.cellA, "")
	in.ProblemID, in.WarehouseID, in.CreatedBy, in.ToInternalWarehouseID, in.Reason =
		uuid.NewString(), mf.wh, mf.user, defect, model.ProblemReasonExpired
	mustNoErr(t, repository.ProblemSubmitForTest(ctx, mf.pool, in))
	if err := repository.ProblemSubmitForTest(ctx, mf.pool, in); !errors.Is(err, repository.ErrProblemPosted) {
		t.Errorf("повтор: %v", err)
	}
	if main, def, box := mf.qtyIn(t, mf.cellA, mf.iwh), mf.qtyIn(t, mf.cellA, defect), mf.luQty(t, lu); main != "16" || def != "1" || box != "12.000" {
		t.Errorf("отказы сдвинули остаток: основной %s брак %s короб %s", main, def, box)
	}
}
