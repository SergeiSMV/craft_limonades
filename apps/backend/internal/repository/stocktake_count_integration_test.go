package repository_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// counting заводит пересчёт по ячейкам, берёт их работником фикстуры и начинает подсчёт.
// Возвращает пересчёт и ячейки пересчёта по адресу.
func (fx *stocktakeFixture) counting(t *testing.T, cells ...string) (model.StocktakeCreated, map[string]string) {
	t.Helper()
	st, err := fx.create(model.StocktakeScopeCells, cells...)
	mustNoErr(t, err)
	ids := fx.cellsOf(t, st.ID)
	for _, id := range ids {
		mustNoErr(t, fx.repo.Take(context.Background(), id, fx.user, 0))
		if _, err := fx.repo.StartCount(context.Background(), id, fx.user); err != nil {
			t.Fatalf("начать подсчёт: %v", err)
		}
	}
	return st, ids
}

// submit проводит подсчёт ячейки новой операцией очереди.
func (fx *stocktakeFixture) submit(stCell string, boxes []string, loose ...model.StocktakeLooseFact) (repository.Applied, error) {
	return fx.ops.StocktakeCellSubmit(context.Background(), uuid.NewString(), model.StocktakeCellSubmitInput{
		StocktakeCellID: stCell, UserID: fx.user, Loose: loose, Boxes: boxes,
	})
}

// qty — остаток позиции (вместе с коробами — как в stock).
func (fx *stocktakeFixture) qty(t *testing.T, cell, good, batch, iwh string) string {
	t.Helper()
	q, err := repository.NewStockRepository(fx.pool).GetQty(context.Background(), model.StockKey{
		CellID: cell, GoodID: good, BatchID: batch, InternalWarehouseID: iwh,
	})
	mustNoErr(t, err)
	return q.String()
}

func (fx *stocktakeFixture) notFoundIwh(t *testing.T) string {
	t.Helper()
	var id string
	mustScan(t, fx.pool, `SELECT id::text FROM internal_warehouses WHERE system_role = 'not_found'`, &id)
	return id
}

func fact(good, date, iwh string, qty int64, marks ...string) model.StocktakeLooseFact {
	return model.StocktakeLooseFact{GoodID: good, ProductionDate: date, InternalWarehouseID: iwh,
		Qty: decimal.NewFromInt(qty), Marks: marks}
}

// P10-03: подсчёт приводит остаток к факту сразу — недостача, излишек новой партией,
// не названная позиция «Брака» — ноль; каждая правка — строкой audit_log.
func TestStocktakeCount_shortageAndSurplus(t *testing.T) {
	fx := setupStocktake(t)
	fx.put(t, fx.cellB, fx.good, fx.batch, fx.iwh, 5)
	fx.put(t, fx.cellB, fx.good, fx.batch, fx.iwhDefect, 2)
	_, cells := fx.counting(t, fx.cellB)

	applied, err := fx.submit(cells["B"], nil,
		fact(fx.good, "2026-01-01", "", 3),
		fact(fx.good, "2026-03-01", fx.iwh, 4))
	mustNoErr(t, err)
	if string(applied.Result) != `{"adjustments":3,"moved_boxes":0,"problems":0}` {
		t.Errorf("итог подсчёта: %s", applied.Result)
	}
	var batch3 string
	mustScan(t, fx.pool, `SELECT id::text FROM batches WHERE good_id = $1::uuid AND production_date = '2026-03-01'`,
		&batch3, fx.good)
	for what, c := range map[string]struct{ got, want string }{
		"недостача «Основного»": {fx.qty(t, fx.cellB, fx.good, fx.batch, fx.iwh), "3"},
		"«Брак» не назван — 0":  {fx.qty(t, fx.cellB, fx.good, fx.batch, fx.iwhDefect), "0"},
		"излишек новой партией": {fx.qty(t, fx.cellB, fx.good, batch3, fx.iwh), "4"},
		"ячейка подсчитана":     {fx.cellStatus(t, cells["B"]), "counted"},
	} {
		if c.got != c.want {
			t.Errorf("%s: %s, ожидалось %s", what, c.got, c.want)
		}
	}
	var audits int
	mustScanInt(t, fx.putawayFixture, `SELECT count(*) FROM audit_log WHERE action = 'stocktake.adjust'
		AND details->>'stocktake_cell_id' = $1`, &audits, cells["B"])
	if audits != 3 {
		t.Errorf("правок в audit_log: %d, ожидалось 3", audits)
	}

	// Повтор операции эффекта не повторяет, второй подсчёт той же ячейки — отказ.
	if _, err := fx.submit(cells["B"], nil); !errors.Is(err, model.ErrStocktakeCellCounted) {
		t.Errorf("второй подсчёт: ожидался ErrStocktakeCellCounted, получено %v", err)
	}
}

// P10-03: короб из снимка не найден — проблема «не найдено», короб на складе «Не найдено»;
// учётный короб из другой ячейки переносится сюда журналом размещений; неизвестный — отказ.
// «Нашлось» офиса возвращает короб в «Основной».
func TestStocktakeCount_boxes(t *testing.T) {
	fx := setupStocktake(t)
	ctx := context.Background()
	lost := fx.box(t, fx.cellB, 12)
	foreign := fx.box(t, fx.cellC, 6)
	_, cells := fx.counting(t, fx.cellB)

	if _, err := fx.submit(cells["B"], []string{uuid.NewString()}); !errors.Is(err, model.ErrStocktakeUnknownBox) {
		t.Fatalf("неизвестный короб: ожидался ErrStocktakeUnknownBox, получено %v", err)
	}
	if s := fx.cellStatus(t, cells["B"]); s != "counting" {
		t.Errorf("отказ оставил ячейку %s — ожидалось counting", s)
	}

	applied, err := fx.submit(cells["B"], []string{foreign})
	mustNoErr(t, err)
	if string(applied.Result) != `{"adjustments":0,"moved_boxes":1,"problems":1}` {
		t.Errorf("итог подсчёта: %s", applied.Result)
	}
	var lostIwh, problem, foreignCell, source string
	mustScan(t, fx.pool, `SELECT internal_warehouse_id::text FROM load_units WHERE id = $1::uuid`, &lostIwh, lost)
	mustScan(t, fx.pool, `SELECT problem_id::text FROM stocktake_lines WHERE load_unit_id = $1::uuid`, &problem, lost)
	mustScan(t, fx.pool, `SELECT cell_id::text FROM load_units WHERE id = $1::uuid`, &foreignCell, foreign)
	mustScan(t, fx.pool, `SELECT source FROM placements WHERE load_unit_id = $1::uuid
		ORDER BY placed_at DESC LIMIT 1`, &source, foreign)
	if lostIwh != fx.notFoundIwh(t) || problem == "" {
		t.Errorf("не найденный короб: склад %s, проблема %q", lostIwh, problem)
	}
	if foreignCell != fx.cellB || source != model.PlacementStocktake {
		t.Errorf("найденный короб: ячейка %s, источник %s", foreignCell, source)
	}
	if b, c := fx.qty(t, fx.cellB, fx.good, fx.batch, fx.iwh), fx.qty(t, fx.cellC, fx.good, fx.batch, fx.iwh); b != "6" || c != "0" {
		t.Errorf("остаток «Основного»: B=%s C=%s, ожидалось 6 и 0", b, c)
	}

	if err := repository.NewProblemRepository(fx.pool).Resolve(ctx, model.ResolveProblemInput{
		ProblemID: problem, Decision: model.ProblemDecisionPlace, ResolvedBy: fx.user,
	}); err != nil {
		t.Fatalf("«нашлось»: %v", err)
	}
	mustScan(t, fx.pool, `SELECT internal_warehouse_id::text FROM load_units WHERE id = $1::uuid`, &lostIwh, lost)
	if lostIwh != fx.iwh {
		t.Errorf("после «нашлось» короб на складе %s — ожидался «Основной»", lostIwh)
	}
}

// P10-03: маркируемый товар — марками. Не найденная марка — проблема «не найдено» с этой
// маркой; марка из другой ячейки переносится сюда с единицей остатка; марки нет на складе —
// отказ.
func TestStocktakeCount_marks(t *testing.T) {
	fx := setupStocktake(t)
	const (
		m1, m2, m3, m4 = "0104600000000017215L1", "0104600000000017215L2", "0104600000000017215L3", "0104600000000017215L4"
	)
	fx.put(t, fx.cellB, fx.good2, fx.batch2, fx.iwh, 3)
	fx.mark(t, fx.cellB, m1)
	fx.mark(t, fx.cellB, m2)
	fx.mark(t, fx.cellB, m3)
	fx.put(t, fx.cellC, fx.good2, fx.batch2, fx.iwh, 1)
	fx.mark(t, fx.cellC, m4)
	_, cells := fx.counting(t, fx.cellB)

	for name, c := range map[string]struct {
		f    model.StocktakeLooseFact
		want error
	}{
		"без марок":        {fact(fx.good2, "2026-02-01", "", 3), model.ErrStocktakeMarksRequired},
		"марки нет в WMS":  {fact(fx.good2, "2026-02-01", "", 1, "0104600000000017215L9"), model.ErrStocktakeUnknownMark},
		"марок не столько": {fact(fx.good2, "2026-02-01", "", 3, m1), model.ErrCZMarksQtyMismatch},
	} {
		if _, err := fx.submit(cells["B"], nil, c.f); !errors.Is(err, c.want) {
			t.Errorf("%s: ожидалось %v, получено %v", name, c.want, err)
		}
	}

	applied, err := fx.submit(cells["B"], nil, fact(fx.good2, "2026-02-01", "", 3, m1, m2, m4))
	mustNoErr(t, err)
	if string(applied.Result) != `{"adjustments":0,"moved_boxes":0,"problems":1}` {
		t.Errorf("итог подсчёта: %s", applied.Result)
	}
	var m3Iwh, m4Cell, m3Problem string
	mustScan(t, fx.pool, `SELECT internal_warehouse_id::text FROM cz_marks WHERE cis = $1`, &m3Iwh, m3)
	mustScan(t, fx.pool, `SELECT cell_id::text FROM cz_marks WHERE cis = $1`, &m4Cell, m4)
	mustScan(t, fx.pool, `SELECT COALESCE(problem_id::text, '') FROM stocktake_marks WHERE cis = $1`, &m3Problem, m3)
	if m3Iwh != fx.notFoundIwh(t) || m3Problem == "" {
		t.Errorf("не найденная марка: склад %s, проблема %q", m3Iwh, m3Problem)
	}
	if m4Cell != fx.cellB {
		t.Errorf("марка из C не перенесена: ячейка %s", m4Cell)
	}
	for what, c := range map[string]struct{ got, want string }{
		"«Основной» в B":    {fx.qty(t, fx.cellB, fx.good2, fx.batch2, fx.iwh), "3"},
		"«Не найдено» в B":  {fx.qty(t, fx.cellB, fx.good2, fx.batch2, fx.notFoundIwh(t)), "1"},
		"единица ушла из C": {fx.qty(t, fx.cellC, fx.good2, fx.batch2, fx.iwh), "0"},
	} {
		if c.got != c.want {
			t.Errorf("%s: %s, ожидалось %s", what, c.got, c.want)
		}
	}
}

// P10-03: подсчёт только своей начатой ячейки, не сбитой, в открытом пересчёте и по товару
// области.
func TestStocktakeCount_rejects(t *testing.T) {
	fx := setupStocktake(t)
	ctx := context.Background()
	fx.put(t, fx.cellB, fx.good, fx.batch, fx.iwh, 5)
	fx.put(t, fx.cellC, fx.good2, fx.batch2, fx.iwh, 1)
	st, cells := fx.counting(t, fx.cellB, fx.cellD)
	other := newUserNamed(t, fx.putawayFixture, "90000088", "Другой")

	if _, err := fx.ops.StocktakeCellSubmit(ctx, uuid.NewString(), model.StocktakeCellSubmitInput{
		StocktakeCellID: cells["B"], UserID: other,
	}); !errors.Is(err, model.ErrStocktakeCellNotYours) {
		t.Errorf("чужая ячейка: %v", err)
	}
	fx.put(t, fx.cellB, fx.good, fx.batch, fx.iwh, 1)
	if _, err := fx.submit(cells["B"], nil); !errors.Is(err, model.ErrStocktakeCellDisrupted) {
		t.Errorf("сбитая ячейка: %v", err)
	}
	mustNoErr(t, fx.repo.Release(ctx, cells["D"], fx.user))
	if _, err := fx.submit(cells["D"], nil); !errors.Is(err, model.ErrStocktakeCellNotYours) {
		t.Errorf("отданная ячейка: %v", err)
	}

	area, err := fx.create(model.StocktakeScopeGood, fx.good2)
	mustNoErr(t, err)
	stC := fx.cellsOf(t, area.ID)["C"]
	mustNoErr(t, fx.repo.Take(ctx, stC, fx.user, 0))
	_, err = fx.repo.StartCount(ctx, stC, fx.user)
	mustNoErr(t, err)
	if _, err := fx.submit(stC, nil, fact(fx.good, "2026-01-01", "", 1)); !errors.Is(err, model.ErrStocktakeOutOfArea) {
		t.Errorf("товар не области: %v", err)
	}

	if _, err := fx.repo.Close(ctx, st.ID, fx.user, true); err != nil {
		t.Fatalf("закрыть: %v", err)
	}
	if _, err := fx.submit(cells["B"], nil); !errors.Is(err, model.ErrStocktakeClosed) {
		t.Errorf("закрытый пересчёт: %v", err)
	}
}

// P10-03: ячейку держит один работник; зависшую взятую берёт другой; отказ отбрасывает подсчёт;
// закрыть с неподсчитанными ячейками — только с подтверждением, задание уходит в выполненные.
func TestStocktake_takeReleaseClose(t *testing.T) {
	fx := setupStocktake(t)
	ctx := context.Background()
	fx.put(t, fx.cellB, fx.good, fx.batch, fx.iwh, 5)
	st, err := fx.create(model.StocktakeScopeCells, fx.cellB, fx.cellD)
	mustNoErr(t, err)
	cells := fx.cellsOf(t, st.ID)
	other := newUserNamed(t, fx.putawayFixture, "90000088", "Другой")

	mustNoErr(t, fx.repo.Take(ctx, cells["B"], fx.user, service8h))
	if err := fx.repo.Take(ctx, cells["B"], other, service8h); !errors.Is(err, model.ErrStocktakeCellBusy) {
		t.Errorf("чужая взятая: %v", err)
	}
	free, err := fx.repo.Cells(ctx, st.ID, other, service8h)
	mustNoErr(t, err)
	if len(free) != 1 || free[0].Address != "D" {
		t.Errorf("другому видны %+v — ожидалась только D", free)
	}
	if _, err := fx.pool.Exec(ctx, `UPDATE stocktake_cells SET taken_at = now() - interval '9 hours'
		WHERE id = $1::uuid`, cells["B"]); err != nil {
		t.Fatal(err)
	}
	mustNoErr(t, fx.repo.Take(ctx, cells["B"], other, service8h))
	if err := fx.repo.Release(ctx, cells["B"], fx.user); !errors.Is(err, model.ErrStocktakeCellNotYours) {
		t.Errorf("отказ от перехваченной: %v", err)
	}

	if _, err := fx.repo.StartCount(ctx, cells["B"], other); err != nil {
		t.Fatalf("начать: %v", err)
	}
	mustNoErr(t, fx.repo.Release(ctx, cells["B"], other))
	var lines int
	mustScanInt(t, fx.putawayFixture, `SELECT count(*) FROM stocktake_lines WHERE stocktake_cell_id = $1::uuid`, &lines, cells["B"])
	if s := fx.cellStatus(t, cells["B"]); s != "pending" || lines != 0 {
		t.Errorf("после отказа: %s, строк %d", s, lines)
	}

	if _, err := fx.repo.Close(ctx, st.ID, fx.user, false); !errors.Is(err, model.ErrStocktakeUncounted) {
		t.Errorf("закрытие без подтверждения: %v", err)
	}
	uncounted, err := fx.repo.Close(ctx, st.ID, fx.user, true)
	mustNoErr(t, err)
	var taskStatus string
	mustScan(t, fx.pool, `SELECT status FROM warehouse_tasks WHERE stocktake_id = $1::uuid`, &taskStatus, st.ID)
	if uncounted != 2 || taskStatus != model.TaskDone {
		t.Errorf("закрыто: неподсчитанных %d, задание %s", uncounted, taskStatus)
	}
	if fx.qty(t, fx.cellB, fx.good, fx.batch, fx.iwh) != "5" {
		t.Error("досрочное закрытие тронуло остаток неподсчитанной ячейки")
	}
	if _, err := fx.repo.Close(ctx, st.ID, fx.user, true); !errors.Is(err, model.ErrStocktakeClosed) {
		t.Errorf("второе закрытие: %v", err)
	}
}

// service8h — срок зависания взятой ячейки, как в сервисе.
const service8h = 8 * time.Hour
