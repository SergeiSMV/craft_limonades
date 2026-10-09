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

// Тесты P5-02 (проведение сеанса размещения) и P5-02-1 (сеанс выполняет задание).
// Ячейка A фикстуры — ячейка приёмки (дефолтная), B — ячейка хранения. Всё, что приёмка
// кладёт в A, становится заданием на размещение.

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

// receive оприходует приёмку в ячейку приёмки: короба по 12 шт и россыпь заданным количеством.
// Возвращает задание на размещение, которое родилось из неё.
func (pf *putawayFixture) receive(t *testing.T, boxes []string, loose int64) string {
	t.Helper()
	ctx := context.Background()
	repo := repository.NewReceiptRepository(pf.pool)
	receipt := uuid.NewString()
	mustNoErr(t, repo.Create(ctx, receipt, pf.wh, "", pf.user))
	for _, lu := range boxes {
		mustNoErr(t, repo.AddLine(ctx, receipt, model.ReceiptLineInput{
			GoodID: pf.good, ProductionDate: "2026-01-01", CellID: pf.cellA, LoadUnitID: lu,
			Qty: decimal.NewFromInt(12),
		}))
	}
	if loose > 0 {
		mustNoErr(t, repo.AddLine(ctx, receipt, model.ReceiptLineInput{
			GoodID: pf.good, ProductionDate: "2026-01-01", CellID: pf.cellA, Qty: decimal.NewFromInt(loose),
		}))
	}
	if _, err := repo.Post(ctx, receipt); err != nil {
		t.Fatalf("оприходовать приёмку: %v", err)
	}
	var task string
	mustScan(t, pf.pool, `SELECT id::text FROM warehouse_tasks WHERE receipt_id = $1::uuid`, &task, receipt)
	return task
}

// submit проводит сеанс размещения по заданию новой операцией.
func (pf *putawayFixture) submit(t *testing.T, task, putaway string, lines ...repository.PutawayLineInput) (repository.Applied, error) {
	t.Helper()
	return pf.ops.PutawaySubmit(context.Background(), uuid.NewString(), repository.PutawaySubmitInput{
		PutawayID: putaway, TaskID: task, WarehouseID: pf.wh, CreatedBy: pf.user, Lines: lines,
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
	task := pf.receive(t, []string{lu}, 0)

	putaway := uuid.NewString()
	if _, err := pf.submit(t, task, putaway, boxTo(lu, pf.cellB)); err != nil {
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
}

// Россыпь берётся из ячейки приёмки, но только та, что не лежит там же в коробах: даже если
// задание разрешает больше, товар из-под короба не уходит.
func TestPutaway_looseExcludesBoxedStock(t *testing.T) {
	pf := setupPutaway(t)
	lu := newLU(t, pf.stockFixture, model.LoadUnitBox)
	task := pf.receive(t, []string{lu}, 5) // в ячейке A: 12 в коробе + 5 россыпью
	// Россыпь кто-то унёс мимо учёта задания: остаток A = 15, россыпи в нём 3.
	mustNoErr(t, repository.NewStockRepository(pf.pool).Remove(context.Background(), model.StockKey{
		CellID: pf.cellA, GoodID: pf.good, BatchID: pf.batch, InternalWarehouseID: pf.iwh,
	}, decimal.NewFromInt(2)))

	if _, err := pf.submit(t, task, uuid.NewString(), looseTo(pf.good, 4, pf.cellB)); !errors.Is(err, repository.ErrLooseStockShort) {
		t.Fatalf("россыпь сверх лежащей: %v, ожидалась ErrLooseStockShort", err)
	}
	if _, err := pf.submit(t, task, uuid.NewString(), looseTo(pf.good, 3, pf.cellB)); err != nil {
		t.Fatalf("размещение россыпи: %v", err)
	}
	if a, b := pf.qtyIn(t, pf.cellA), pf.qtyIn(t, pf.cellB); a != "12" || b != "3" {
		t.Errorf("остаток A=%s B=%s, ожидалось 12 (короб) и 3", a, b)
	}
}

// Сеанс проводится целиком: отказ строки откатывает и уже проведённые строки.
func TestPutaway_sessionIsAtomic(t *testing.T) {
	pf := setupPutaway(t)
	lu := newLU(t, pf.stockFixture, model.LoadUnitBox)
	task := pf.receive(t, []string{lu}, 5)

	putaway := uuid.NewString()
	_, err := pf.submit(t, task, putaway, boxTo(lu, pf.cellB), looseTo(pf.good, 6, pf.cellB))
	if !errors.Is(err, repository.ErrExceedsTask) {
		t.Fatalf("вторая строка: %v, ожидалась ErrExceedsTask", err)
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
	lu1, lu2 := newLU(t, pf.stockFixture, model.LoadUnitBox), newLU(t, pf.stockFixture, model.LoadUnitBox)
	task := pf.receive(t, []string{lu1, lu2}, 0)

	opID, putaway := uuid.NewString(), uuid.NewString()
	in := repository.PutawaySubmitInput{PutawayID: putaway, TaskID: task, WarehouseID: pf.wh, CreatedBy: pf.user,
		Lines: []repository.PutawayLineInput{boxTo(lu1, pf.cellB)}}
	if _, err := pf.ops.PutawaySubmit(ctx, opID, in); err != nil {
		t.Fatalf("первая попытка: %v", err)
	}
	again, err := pf.ops.PutawaySubmit(ctx, opID, in)
	if err != nil || !again.Duplicate {
		t.Fatalf("повтор операции: err=%v duplicate=%v", err, again.Duplicate)
	}
	in.Lines = []repository.PutawayLineInput{boxTo(lu2, pf.cellB)}
	if _, err := pf.ops.PutawaySubmit(ctx, uuid.NewString(), in); !errors.Is(err, repository.ErrPutawayPosted) {
		t.Fatalf("тот же сеанс новой операцией: %v, ожидалась ErrPutawayPosted", err)
	}
	if pf.qtyIn(t, pf.cellB) != "12" {
		t.Error("повтор сдвинул остаток второй раз")
	}
}

// Отказы по существу: чужое задание, короб не из задания, перенос на место, чужой склад.
func TestPutaway_rejections(t *testing.T) {
	pf := setupPutaway(t)
	placed := newLU(t, pf.stockFixture, model.LoadUnitBox)
	task := pf.receive(t, []string{placed}, 5)
	stranger := newLU(t, pf.stockFixture, model.LoadUnitBox)
	pf.receive(t, []string{stranger}, 0) // короб другого задания уже на складе

	var otherWh, foreign string
	mustScan(t, pf.pool, `INSERT INTO warehouses (code, name) VALUES ('WH2','другой') RETURNING id::text`, &otherWh)
	mustScan(t, pf.pool, `INSERT INTO cells (warehouse_id, address) VALUES ($1::uuid,'Z') RETURNING id::text`, &foreign, otherWh)

	cases := []struct {
		name string
		task string
		line repository.PutawayLineInput
		want error
	}{
		{"короб другого задания", task, boxTo(stranger, pf.cellB), repository.ErrNotInTask},
		{"неизвестное задание", uuid.NewString(), boxTo(placed, pf.cellB), repository.ErrTaskNotFound},
		{"россыпь не той партии", task, repository.PutawayLineInput{GoodID: pf.good, ProductionDate: "2025-01-01",
			Qty: decimal.NewFromInt(1), ToCellID: pf.cellB}, repository.ErrNotInTask},
		{"россыпи больше, чем в задании", task, looseTo(pf.good, 6, pf.cellB), repository.ErrExceedsTask},
		{"короб на то же место", task, boxTo(placed, pf.cellA), repository.ErrPutawaySameCell},
		{"россыпь в ячейку приёмки", task, looseTo(pf.good, 1, pf.cellA), repository.ErrPutawaySameCell},
		{"ячейка чужого склада", task, boxTo(placed, foreign), repository.ErrForeignCell},
		{"неизвестная ячейка", task, boxTo(placed, uuid.NewString()), repository.ErrUnknownReference},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := pf.submit(t, tc.task, uuid.NewString(), tc.line); !errors.Is(err, tc.want) {
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

// ADHOC-21: россыпь, унесённая размещением целиком, не остаётся в «где лежит товар» строкой
// с нулём — расход уменьшает строку остатка, а не удаляет её, и список обязан её скрывать.
func TestPutaway_emptiedCellNotListedAsStock(t *testing.T) {
	pf := setupPutaway(t)
	task := pf.receive(t, nil, 5)
	if _, err := pf.submit(t, task, uuid.NewString(), looseTo(pf.good, 5, pf.cellB)); err != nil {
		t.Fatalf("размещение россыпи: %v", err)
	}
	if a := pf.qtyIn(t, pf.cellA); a != "0" {
		t.Fatalf("в ячейке приёмки осталось %s, ожидалось 0 — сценарий не тот", a)
	}

	good := pf.good
	items, total, err := repository.NewStockRepository(pf.pool).List(context.Background(),
		repository.StockFilter{GoodID: &good, Limit: 50})
	mustNoErr(t, err)
	if total != 1 || len(items) != 1 || items[0].CellID != pf.cellB {
		t.Errorf("остатки товара: %d строк (total %d): %+v, ожидалась одна — в B", len(items), total, items)
	}
}
