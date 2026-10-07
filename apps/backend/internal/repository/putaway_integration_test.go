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

// Тесты P5-02: проведение сеанса размещения. Критерий задачи — размещаются короб и россыпь,
// атомарно. Ячейка A фикстуры становится ячейкой приёмки (дефолтной), B — ячейкой хранения.

type putawayFixture struct {
	*stockFixture
	user string
	wh   string
	ops  *repository.OperationsRepository
}

func setupPutaway(t *testing.T) *putawayFixture {
	t.Helper()
	fx := setupStock(t)
	if _, err := fx.pool.Exec(context.Background(),
		`UPDATE cells SET is_default = true WHERE id = $1::uuid`, fx.cellA); err != nil {
		t.Fatalf("сделать A ячейкой приёмки: %v", err)
	}
	pf := &putawayFixture{stockFixture: fx, user: newUser(t, fx), ops: repository.NewOperationsRepository(fx.pool)}
	mustScan(t, fx.pool, `SELECT warehouse_id::text FROM cells WHERE id = $1::uuid`, &pf.wh, fx.cellA)
	return pf
}

// receiveLoose принимает россыпь в ячейку приёмки.
func (pf *putawayFixture) receiveLoose(t *testing.T, qty int64) {
	t.Helper()
	ctx := context.Background()
	repo := repository.NewReceiptRepository(pf.pool)
	receipt := uuid.NewString()
	mustNoErr(t, repo.Create(ctx, receipt, pf.wh, "", pf.user))
	mustNoErr(t, repo.AddLine(ctx, receipt, model.ReceiptLineInput{
		GoodID: pf.good, ProductionDate: "2026-01-01", CellID: pf.cellA, Qty: decimal.NewFromInt(qty),
	}))
	if _, err := repo.Post(ctx, receipt); err != nil {
		t.Fatalf("оприходовать россыпь: %v", err)
	}
}

// submit проводит сеанс размещения новой операцией.
func (pf *putawayFixture) submit(t *testing.T, putaway string, lines ...repository.PutawayLineInput) (repository.Applied, error) {
	t.Helper()
	return pf.ops.PutawaySubmit(context.Background(), uuid.NewString(), repository.PutawaySubmitInput{
		PutawayID: putaway, WarehouseID: pf.wh, CreatedBy: pf.user, Lines: lines,
	})
}

func boxTo(lu, cell string) repository.PutawayLineInput {
	return repository.PutawayLineInput{LoadUnitID: lu, ToCellID: cell}
}

func looseTo(good string, qty int64, cell string) repository.PutawayLineInput {
	return repository.PutawayLineInput{
		GoodID: good, ProductionDate: "2026-01-01", Qty: decimal.NewFromInt(qty), ToCellID: cell,
	}
}

// qtyIn — остаток товара фикстуры в ячейке (склад по умолчанию).
func (pf *putawayFixture) qtyIn(t *testing.T, cell string) string {
	t.Helper()
	q, err := repository.NewStockRepository(pf.pool).GetQty(context.Background(), model.StockKey{
		CellID: cell, GoodID: pf.good, BatchID: pf.batch, InternalWarehouseID: pf.iwh,
	})
	mustNoErr(t, err)
	return q.String()
}

// Короб переезжает целиком: остаток по составу, место, журнал со ссылкой на документ.
func TestPutaway_boxMovesWithStockAndHistory(t *testing.T) {
	pf := setupPutaway(t)
	lu := newLU(t, pf.stockFixture, model.LoadUnitBox)
	receiveBox(t, pf.stockFixture, pf.user, lu, pf.cellA) // 12 шт в коробе

	putaway := uuid.NewString()
	if _, err := pf.submit(t, putaway, boxTo(lu, pf.cellB)); err != nil {
		t.Fatalf("размещение короба: %v", err)
	}

	if a, b := pf.qtyIn(t, pf.cellA), pf.qtyIn(t, pf.cellB); a != "0" || b != "12" {
		t.Errorf("остаток A=%s B=%s, ожидалось 0 и 12", a, b)
	}
	if currentCell(t, pf.stockFixture, lu) != pf.cellB {
		t.Error("короб не переехал в B")
	}
	hist, err := repository.NewLoadUnitRepository(pf.pool).Placements(context.Background(), lu)
	mustNoErr(t, err)
	last := hist[len(hist)-1]
	if len(hist) != 2 || last.Source != model.PlacementPutaway || last.PutawayID == nil || *last.PutawayID != putaway {
		t.Errorf("журнал: %d строк, последняя %+v", len(hist), last)
	}
	var lines int
	mustScanInt(t, pf, `SELECT count(*) FROM putaway_lines WHERE putaway_id = $1::uuid AND load_unit_id IS NOT NULL`, &lines, putaway)
	if lines != 1 {
		t.Errorf("строк документа с коробом: %d", lines)
	}
}

// Россыпь берётся из ячейки приёмки, но только та, что не лежит там же в коробах.
func TestPutaway_looseExcludesBoxedStock(t *testing.T) {
	pf := setupPutaway(t)
	lu := newLU(t, pf.stockFixture, model.LoadUnitBox)
	receiveBox(t, pf.stockFixture, pf.user, lu, pf.cellA) // 12 в коробе
	pf.receiveLoose(t, 5)                                 // 5 россыпью; в ячейке A всего 17

	// 6 штук россыпью нет: остаток ячейки 17, но 12 из них — в коробе.
	if _, err := pf.submit(t, uuid.NewString(), looseTo(pf.good, 6, pf.cellB)); !errors.Is(err, repository.ErrLooseStockShort) {
		t.Fatalf("россыпь сверх лежащей: %v, ожидалась ErrLooseStockShort", err)
	}
	if a := pf.qtyIn(t, pf.cellA); a != "17" {
		t.Fatalf("отказ сдвинул остаток: A=%s", a)
	}

	if _, err := pf.submit(t, uuid.NewString(), looseTo(pf.good, 5, pf.cellB)); err != nil {
		t.Fatalf("размещение россыпи: %v", err)
	}
	if a, b := pf.qtyIn(t, pf.cellA), pf.qtyIn(t, pf.cellB); a != "12" || b != "5" {
		t.Errorf("остаток A=%s B=%s, ожидалось 12 (короб) и 5", a, b)
	}
	if currentCell(t, pf.stockFixture, lu) != pf.cellA {
		t.Error("россыпь сдвинула короб")
	}
}

// Сеанс проводится целиком: отказ строки откатывает и уже проведённые строки.
func TestPutaway_sessionIsAtomic(t *testing.T) {
	pf := setupPutaway(t)
	lu := newLU(t, pf.stockFixture, model.LoadUnitBox)
	receiveBox(t, pf.stockFixture, pf.user, lu, pf.cellA)

	putaway := uuid.NewString()
	_, err := pf.submit(t, putaway, boxTo(lu, pf.cellB), looseTo(pf.good, 1, pf.cellB))
	if !errors.Is(err, repository.ErrLooseStockShort) {
		t.Fatalf("вторая строка: %v, ожидалась ErrLooseStockShort", err)
	}
	if currentCell(t, pf.stockFixture, lu) != pf.cellA || pf.qtyIn(t, pf.cellB) != "0" {
		t.Error("первая строка проведена, хотя сеанс отклонён")
	}
	var docs int
	mustScanInt(t, pf, `SELECT count(*) FROM putaways WHERE id = $1::uuid`, &docs, putaway)
	if docs != 0 {
		t.Error("отклонённый сеанс оставил документ")
	}
}

// Повтор той же операции — ответ первой попытки; тот же сеанс другой операцией — отказ.
func TestPutaway_repeats(t *testing.T) {
	pf := setupPutaway(t)
	ctx := context.Background()
	lu := newLU(t, pf.stockFixture, model.LoadUnitBox)
	receiveBox(t, pf.stockFixture, pf.user, lu, pf.cellA)

	opID, putaway := uuid.NewString(), uuid.NewString()
	in := repository.PutawaySubmitInput{PutawayID: putaway, WarehouseID: pf.wh, CreatedBy: pf.user,
		Lines: []repository.PutawayLineInput{boxTo(lu, pf.cellB)}}
	if _, err := pf.ops.PutawaySubmit(ctx, opID, in); err != nil {
		t.Fatalf("первая попытка: %v", err)
	}
	again, err := pf.ops.PutawaySubmit(ctx, opID, in)
	if err != nil || !again.Duplicate {
		t.Fatalf("повтор операции: err=%v duplicate=%v", err, again.Duplicate)
	}
	if _, err := pf.ops.PutawaySubmit(ctx, uuid.NewString(), in); !errors.Is(err, repository.ErrPutawayPosted) {
		t.Fatalf("тот же сеанс новой операцией: %v, ожидалась ErrPutawayPosted", err)
	}
	if pf.qtyIn(t, pf.cellB) != "12" {
		t.Error("повтор сдвинул остаток второй раз")
	}
}

// Отказы по существу: короб не на складе, перенос на место, чужой склад, неизвестная ячейка.
func TestPutaway_rejections(t *testing.T) {
	pf := setupPutaway(t)
	placed := newLU(t, pf.stockFixture, model.LoadUnitBox)
	receiveBox(t, pf.stockFixture, pf.user, placed, pf.cellA)
	fresh := newLU(t, pf.stockFixture, model.LoadUnitBox)

	var otherWh, foreign string
	mustScan(t, pf.pool, `INSERT INTO warehouses (code, name) VALUES ('WH2','другой') RETURNING id::text`, &otherWh)
	mustScan(t, pf.pool, `INSERT INTO cells (warehouse_id, address) VALUES ($1::uuid,'Z') RETURNING id::text`, &foreign, otherWh)

	cases := []struct {
		name string
		line repository.PutawayLineInput
		want error
	}{
		{"короб не принят", boxTo(fresh, pf.cellB), repository.ErrLoadUnitNotPlaced},
		{"неизвестный короб", boxTo(uuid.NewString(), pf.cellB), repository.ErrLoadUnitNotFound},
		{"короб на то же место", boxTo(placed, pf.cellA), repository.ErrPutawaySameCell},
		{"россыпь в ячейку приёмки", looseTo(pf.good, 1, pf.cellA), repository.ErrPutawaySameCell},
		{"ячейка чужого склада", boxTo(placed, foreign), repository.ErrForeignCell},
		{"неизвестная ячейка", boxTo(placed, uuid.NewString()), repository.ErrUnknownReference},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := pf.submit(t, uuid.NewString(), tc.line); !errors.Is(err, tc.want) {
				t.Errorf("получено %v, ожидалась %v", err, tc.want)
			}
		})
	}
}

func mustScanInt(t *testing.T, pf *putawayFixture, sql string, dst *int, args ...any) {
	t.Helper()
	if err := pf.pool.QueryRow(context.Background(), sql, args...).Scan(dst); err != nil {
		t.Fatalf("%q: %v", sql, err)
	}
}
