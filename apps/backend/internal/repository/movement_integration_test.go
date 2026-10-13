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

// Тесты P6-02: перенос ГЕ перемещением. Критерий задачи — состав едет вместе с ГЕ.
// Фикстура setupPutaway — из putaway_integration_test.go: A — ячейка приёмки, B — хранения;
// здесь добавляется вторая ячейка хранения C.

type moveFixture struct {
	*putawayFixture
	cellC string
}

func setupMove(t *testing.T) *moveFixture {
	t.Helper()
	mf := &moveFixture{putawayFixture: setupPutaway(t)}
	mustScan(t, mf.pool, `INSERT INTO cells (warehouse_id, address) VALUES ($1::uuid,'C') RETURNING id::text`,
		&mf.cellC, mf.wh)
	return mf
}

// move проводит документ перемещения со строками «ГЕ → ячейка».
func (mf *moveFixture) move(t *testing.T, id string, lines ...repository.MovementLineInput) (int, error) {
	t.Helper()
	return repository.MovementSubmitForTest(context.Background(), mf.pool, repository.MovementSubmitInput{
		MovementID: id, Kind: model.MovementMove, WarehouseID: mf.wh, CreatedBy: mf.user, Lines: lines,
	})
}

func luTo(lu, cell string) repository.MovementLineInput {
	return repository.MovementLineInput{LoadUnitID: lu, ToCellID: cell}
}

// qtyOf — остаток партии batch товара фикстуры в ячейке (склад по умолчанию).
func (mf *moveFixture) qtyOf(t *testing.T, cell, batch string) string {
	t.Helper()
	q, err := repository.NewStockRepository(mf.pool).GetQty(context.Background(), model.StockKey{
		CellID: cell, GoodID: mf.good, BatchID: batch, InternalWarehouseID: mf.iwh,
	})
	mustNoErr(t, err)
	return q.String()
}

// receiveMixedBox оприходует короб с двумя партиями (12 и 7) и россыпь 5 рядом в ячейке
// приёмки. Возвращает партию второй позиции.
func (mf *moveFixture) receiveMixedBox(t *testing.T, lu string) string {
	t.Helper()
	ctx := context.Background()
	repo := repository.NewReceiptRepository(mf.pool)
	receipt := uuid.NewString()
	mustNoErr(t, repo.Create(ctx, receipt, mf.wh, "", mf.user, testDoc))
	for _, ln := range []model.ReceiptLineInput{
		{GoodID: mf.good, ProductionDate: "2026-01-01", CellID: mf.cellA, LoadUnitID: lu, Qty: decimal.NewFromInt(12)},
		{GoodID: mf.good, ProductionDate: "2026-02-01", CellID: mf.cellA, LoadUnitID: lu, Qty: decimal.NewFromInt(7)},
		{GoodID: mf.good, ProductionDate: "2026-01-01", CellID: mf.cellA, Qty: decimal.NewFromInt(5)},
	} {
		mustNoErr(t, repo.AddLine(ctx, receipt, ln))
	}
	if _, err := repo.Post(ctx, receipt); err != nil {
		t.Fatalf("оприходовать приёмку: %v", err)
	}
	var batch2 string
	mustScan(t, mf.pool, `SELECT id::text FROM batches WHERE good_id = $1::uuid AND production_date = '2026-02-01'`,
		&batch2, mf.good)
	return batch2
}

// Критерий задачи: короб переезжает со всем составом, россыпь рядом остаётся на месте;
// место, журнал размещений и строка документа ссылаются на перемещение.
func TestMove_loadUnitCarriesContents(t *testing.T) {
	mf := setupMove(t)
	ctx := context.Background()
	lu := newLU(t, mf.stockFixture, model.LoadUnitBox)
	batch2 := mf.receiveMixedBox(t, lu)

	mv := uuid.NewString()
	if _, err := mf.move(t, mv, luTo(lu, mf.cellB)); err != nil {
		t.Fatalf("перемещение короба: %v", err)
	}

	if a1, a2, b1, b2 := mf.qtyOf(t, mf.cellA, mf.batch), mf.qtyOf(t, mf.cellA, batch2),
		mf.qtyOf(t, mf.cellB, mf.batch), mf.qtyOf(t, mf.cellB, batch2); a1 != "5" || a2 != "0" || b1 != "12" || b2 != "7" {
		t.Errorf("остаток A=%s/%s B=%s/%s, ожидалось A=5/0 (россыпь осталась), B=12/7", a1, a2, b1, b2)
	}
	if currentCell(t, mf.stockFixture, lu) != mf.cellB {
		t.Error("короб не переехал в B")
	}
	hist, err := repository.NewLoadUnitRepository(mf.pool).Placements(ctx, lu)
	mustNoErr(t, err)
	last := hist[len(hist)-1]
	if last.Source != model.PlacementMove || last.MovementID == nil || *last.MovementID != mv ||
		last.FromCellID == nil || *last.FromCellID != mf.cellA {
		t.Errorf("журнал размещений: %+v", last)
	}
	var line string
	mustScan(t, mf.pool, `SELECT l.from_cell_id::text || ' ' || l.to_cell_id::text || ' ' || m.kind
		FROM movement_lines l JOIN movements m ON m.id = l.movement_id
		WHERE m.id = $1::uuid AND l.load_unit_id = $2::uuid`, &line, mv, lu)
	if want := mf.cellA + " " + mf.cellB + " move"; line != want {
		t.Errorf("строка документа: %q, ожидалось %q", line, want)
	}
}

// Одну ГЕ можно перенести в документе дважды: вторая строка берёт её оттуда, куда положила
// первая, и состав едет дальше.
func TestMove_sameUnitTwiceInDocument(t *testing.T) {
	mf := setupMove(t)
	lu := newLU(t, mf.stockFixture, model.LoadUnitBox)
	mf.receive(t, []string{lu}, 0)

	if _, err := mf.move(t, uuid.NewString(), luTo(lu, mf.cellB), luTo(lu, mf.cellC)); err != nil {
		t.Fatalf("перемещение A → B → C: %v", err)
	}
	if b, c := mf.qtyOf(t, mf.cellB, mf.batch), mf.qtyOf(t, mf.cellC, mf.batch); b != "0" || c != "12" {
		t.Errorf("остаток B=%s C=%s, ожидалось 0 и 12", b, c)
	}
	var froms string
	mustScan(t, mf.pool, `SELECT string_agg(c.address, '>' ORDER BY l.line_no)
		FROM movement_lines l JOIN cells c ON c.id = l.from_cell_id WHERE l.load_unit_id = $1::uuid`, &froms, lu)
	if froms != "A>B" {
		t.Errorf("откуда по строкам: %s, ожидалось A>B", froms)
	}
}

// Документ проводится целиком: отказ строки откатывает уже перенесённые короба и шапку.
func TestMove_documentIsAtomic(t *testing.T) {
	mf := setupMove(t)
	lu1, lu2 := newLU(t, mf.stockFixture, model.LoadUnitBox), newLU(t, mf.stockFixture, model.LoadUnitBox)
	mf.receive(t, []string{lu1, lu2}, 0)

	mv := uuid.NewString()
	if _, err := mf.move(t, mv, luTo(lu1, mf.cellB), luTo(lu2, mf.cellA)); !errors.Is(err, repository.ErrSameCell) {
		t.Fatalf("вторая строка: %v, ожидалась ErrSameCell", err)
	}
	if currentCell(t, mf.stockFixture, lu1) != mf.cellA || mf.qtyOf(t, mf.cellB, mf.batch) != "0" {
		t.Error("первая строка проведена, хотя документ отклонён")
	}
	var docs string
	mustScan(t, mf.pool, `SELECT count(*)::text FROM movements WHERE id = $1::uuid`, &docs, mv)
	if docs != "0" {
		t.Error("отклонённый документ оставил шапку")
	}
}

// Тот же документ второй раз не проводится: остаток не сдвигается повторно.
func TestMove_repeatIsRejected(t *testing.T) {
	mf := setupMove(t)
	lu := newLU(t, mf.stockFixture, model.LoadUnitBox)
	mf.receive(t, []string{lu}, 0)

	mv := uuid.NewString()
	if _, err := mf.move(t, mv, luTo(lu, mf.cellB)); err != nil {
		t.Fatalf("первая попытка: %v", err)
	}
	if _, err := mf.move(t, mv, luTo(lu, mf.cellC)); !errors.Is(err, repository.ErrMovementPosted) {
		t.Fatalf("повтор документа: %v, ожидалась ErrMovementPosted", err)
	}
	if currentCell(t, mf.stockFixture, lu) != mf.cellB || mf.qtyOf(t, mf.cellC, mf.batch) != "0" {
		t.Error("повтор документа сдвинул короб")
	}
}

// Отказы по существу.
func TestMove_rejections(t *testing.T) {
	mf := setupMove(t)
	ctx := context.Background()
	placed := newLU(t, mf.stockFixture, model.LoadUnitBox)
	mf.receive(t, []string{placed}, 0)
	unplaced := newLU(t, mf.stockFixture, model.LoadUnitBox)

	// Короб в паллете: паллетная логика вне объёма.
	nested, pallet := newLU(t, mf.stockFixture, model.LoadUnitBox), newLU(t, mf.stockFixture, model.LoadUnitPallet)
	mf.receive(t, []string{nested}, 0)
	if _, err := mf.pool.Exec(ctx, `UPDATE load_units SET parent_id = $2::uuid WHERE id = $1::uuid`, nested, pallet); err != nil {
		t.Fatalf("вложить короб в паллету: %v", err)
	}

	var otherWh, foreign string
	mustScan(t, mf.pool, `INSERT INTO warehouses (code, name) VALUES ('WH2','другой') RETURNING id::text`, &otherWh)
	mustScan(t, mf.pool, `INSERT INTO cells (warehouse_id, address) VALUES ($1::uuid,'Z') RETURNING id::text`, &foreign, otherWh)

	cases := []struct {
		name  string
		kind  string
		lines []repository.MovementLineInput
		want  error
	}{
		{"неизвестный вид", "teleport", []repository.MovementLineInput{luTo(placed, mf.cellB)}, repository.ErrUnknownMovementKind},
		{"пустой документ", model.MovementMove, nil, repository.ErrEmptyMovement},
		{"ГЕ целиком пополнением", model.MovementReplenish, []repository.MovementLineInput{luTo(placed, mf.cellB)}, repository.ErrLoadUnitNotMoved},
		{"строка без ГЕ", model.MovementMove, []repository.MovementLineInput{{ToCellID: mf.cellB}}, repository.ErrEmptyMovementLine},
		{"на то же место", model.MovementMove, []repository.MovementLineInput{luTo(placed, mf.cellA)}, repository.ErrSameCell},
		{"неизвестная ГЕ", model.MovementMove, []repository.MovementLineInput{luTo(uuid.NewString(), mf.cellB)}, repository.ErrLoadUnitNotFound},
		{"ГЕ не на складе", model.MovementMove, []repository.MovementLineInput{luTo(unplaced, mf.cellB)}, repository.ErrLoadUnitNotPlaced},
		{"короб в паллете", model.MovementMove, []repository.MovementLineInput{luTo(nested, mf.cellB)}, repository.ErrLoadUnitNested},
		{"ячейка чужого склада", model.MovementMove, []repository.MovementLineInput{luTo(placed, foreign)}, repository.ErrForeignCell},
		{"неизвестная ячейка", model.MovementMove, []repository.MovementLineInput{luTo(placed, uuid.NewString())}, repository.ErrUnknownReference},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := repository.MovementSubmitForTest(ctx, mf.pool, repository.MovementSubmitInput{
				MovementID: uuid.NewString(), Kind: tc.kind, WarehouseID: mf.wh, CreatedBy: mf.user, Lines: tc.lines,
			})
			if !errors.Is(err, tc.want) {
				t.Errorf("получено %v, ожидалась %v", err, tc.want)
			}
		})
	}
	if currentCell(t, mf.stockFixture, placed) != mf.cellA {
		t.Error("отклонённые документы сдвинули короб")
	}
}

// Тесты P6-03: ветка товара. Источник и приёмник — россыпь ячейки или короб в любых сочетаниях.

// goodsLine — строка товара фикстуры партии 01.01 с одним источником и одним приёмником.
func (mf *moveFixture) goodsLine(qty int64, fromCell, fromLU, toCell, toLU string) repository.MovementLineInput {
	return repository.MovementLineInput{
		GoodID: mf.good, ProductionDate: "2026-01-01", Qty: decimal.NewFromInt(qty),
		FromCellID: fromCell, FromLoadUnitID: fromLU, ToCellID: toCell, ToLoadUnitID: toLU,
	}
}

// luQty — количество товара фикстуры партии 01.01 в коробе.
func (mf *moveFixture) luQty(t *testing.T, lu string) string {
	t.Helper()
	var q string
	mustScan(t, mf.pool, `SELECT COALESCE((SELECT qty::text FROM lu_content
		WHERE load_unit_id = $1::uuid AND good_id = $2::uuid AND batch_id = $3::uuid), 'нет')`, &q, lu, mf.good, mf.batch)
	return q
}

// twoBoxes оприходует два короба по 12 и россыпь 5 в A и переносит второй короб в B.
func (mf *moveFixture) twoBoxes(t *testing.T) (boxA, boxB string) {
	t.Helper()
	boxA, boxB = newLU(t, mf.stockFixture, model.LoadUnitBox), newLU(t, mf.stockFixture, model.LoadUnitBox)
	mf.receive(t, []string{boxA, boxB}, 5)
	if _, err := mf.move(t, uuid.NewString(), luTo(boxB, mf.cellB)); err != nil {
		t.Fatalf("перенести второй короб в B: %v", err)
	}
	return boxA, boxB
}

// Все четыре сочетания одним документом: остаток ячеек и состав коробов сходятся после каждой
// строки; движение внутри ячейки меняет состав короба, но не остаток ячейки.
func TestMove_goodsAllCombinations(t *testing.T) {
	mf := setupMove(t)
	boxA, boxB := mf.twoBoxes(t) // A: короб 12 + россыпь 5 = 17; B: короб 12

	mv := uuid.NewString()
	if _, err := mf.move(t, mv,
		mf.goodsLine(2, "", boxA, "", boxB),         // короб → короб другой ячейки
		mf.goodsLine(1, "", boxA, mf.cellA, ""),     // короб → россыпь той же ячейки
		mf.goodsLine(3, mf.cellA, "", "", boxA),     // россыпь → короб той же ячейки
		mf.goodsLine(3, mf.cellA, "", mf.cellB, ""), // россыпь → россыпь другой ячейки
	); err != nil {
		t.Fatalf("движение товара: %v", err)
	}

	if a, b := mf.qtyOf(t, mf.cellA, mf.batch), mf.qtyOf(t, mf.cellB, mf.batch); a != "12" || b != "17" {
		t.Errorf("остаток A=%s B=%s, ожидалось 12 и 17", a, b)
	}
	if ba, bb := mf.luQty(t, boxA), mf.luQty(t, boxB); ba != "12.000" || bb != "14.000" {
		t.Errorf("состав коробов A=%s B=%s, ожидалось 12 и 14", ba, bb)
	}
	var lines string
	mustScan(t, mf.pool, `SELECT string_agg(cf.address || (CASE WHEN l.from_load_unit_id IS NULL THEN '' ELSE '[]' END)
		|| '>' || ct.address || (CASE WHEN l.to_load_unit_id IS NULL THEN '' ELSE '[]' END), ' ' ORDER BY l.line_no)
		FROM movement_lines l JOIN cells cf ON cf.id = l.from_cell_id JOIN cells ct ON ct.id = l.to_cell_id
		WHERE l.movement_id = $1::uuid`, &lines, mv)
	if lines != "A[]>B[] A[]>A A>A[] A>B" {
		t.Errorf("строки документа: %s", lines)
	}
}

// Пополнение двигает товар той же механикой: строка товара проходит и в документе пополнения.
func TestMove_replenishMovesGoods(t *testing.T) {
	mf := setupMove(t)
	_, boxB := mf.twoBoxes(t)

	_, err := repository.MovementSubmitForTest(context.Background(), mf.pool, repository.MovementSubmitInput{
		MovementID: uuid.NewString(), Kind: model.MovementReplenish, WarehouseID: mf.wh, CreatedBy: mf.user,
		Lines: []repository.MovementLineInput{mf.goodsLine(4, "", boxB, mf.cellC, "")},
	})
	if err != nil {
		t.Fatalf("пополнение: %v", err)
	}
	if b, c, box := mf.qtyOf(t, mf.cellB, mf.batch), mf.qtyOf(t, mf.cellC, mf.batch), mf.luQty(t, boxB); b != "8" || c != "4" || box != "8.000" {
		t.Errorf("B=%s C=%s короб=%s, ожидалось 8 / 4 / 8", b, c, box)
	}
}

// Источник проверяется под блокировкой: из короба — не больше его состава, из россыпи — не
// больше остатка ячейки за вычетом её коробов, несуществующей партии в источнике нет.
func TestMove_goodsRejections(t *testing.T) {
	mf := setupMove(t)
	boxA, boxB := mf.twoBoxes(t)
	unplaced := newLU(t, mf.stockFixture, model.LoadUnitBox)

	unknownBatch := mf.goodsLine(1, mf.cellA, "", mf.cellB, "")
	unknownBatch.ProductionDate = "2020-01-01"
	both := mf.goodsLine(1, mf.cellA, boxA, mf.cellB, "")
	zero := mf.goodsLine(1, mf.cellA, "", mf.cellB, "")
	zero.Qty = decimal.Zero

	cases := []struct {
		name string
		line repository.MovementLineInput
		want error
	}{
		{"из короба больше состава", mf.goodsLine(13, "", boxA, mf.cellB, ""), repository.ErrGoodsShort},
		{"россыпи меньше, чем просят", mf.goodsLine(6, mf.cellA, "", mf.cellB, ""), repository.ErrGoodsShort},
		{"россыпь там, где только короб", mf.goodsLine(1, mf.cellB, "", mf.cellC, ""), repository.ErrGoodsShort},
		{"партии нет", unknownBatch, repository.ErrGoodsShort},
		{"россыпь туда же", mf.goodsLine(1, mf.cellA, "", mf.cellA, ""), repository.ErrSamePlace},
		{"короб в себя же", mf.goodsLine(1, "", boxB, "", boxB), repository.ErrSamePlace},
		{"короб не на складе", mf.goodsLine(1, mf.cellA, "", "", unplaced), repository.ErrLoadUnitNotPlaced},
		{"два источника", both, repository.ErrEmptyMovementLine},
		{"нулевое количество", zero, repository.ErrMovementQty},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := mf.move(t, uuid.NewString(), tc.line); !errors.Is(err, tc.want) {
				t.Errorf("получено %v, ожидалась %v", err, tc.want)
			}
		})
	}
	if a, b, ba := mf.qtyOf(t, mf.cellA, mf.batch), mf.qtyOf(t, mf.cellB, mf.batch), mf.luQty(t, boxA); a != "17" || b != "12" || ba != "12.000" {
		t.Errorf("отклонённые документы сдвинули товар: A=%s B=%s короб=%s", a, b, ba)
	}
}
