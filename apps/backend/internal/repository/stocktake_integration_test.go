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

// stocktakeFixture — склад для пересчёта: A — ячейка приёмки, B и C — хранение, D — пустая.
// Второй товар (маркируемый) — в дочерней группе и у поставщика: на нём проверяются области,
// которые считают только свой товар.
type stocktakeFixture struct {
	*putawayFixture
	repo          *repository.StocktakeRepository
	cellC, cellD  string
	good2, batch2 string
	parentGroup   string
	supplier      string
}

func setupStocktake(t *testing.T) *stocktakeFixture {
	t.Helper()
	pf := setupPutaway(t)
	fx := &stocktakeFixture{putawayFixture: pf, repo: repository.NewStocktakeRepository(pf.pool)}
	var child string
	mustScan(t, pf.pool, `INSERT INTO cells (warehouse_id, address) VALUES ($1::uuid, 'C') RETURNING id::text`, &fx.cellC, pf.wh)
	mustScan(t, pf.pool, `INSERT INTO cells (warehouse_id, address) VALUES ($1::uuid, 'D') RETURNING id::text`, &fx.cellD, pf.wh)
	mustScan(t, pf.pool, `INSERT INTO nomenclature_groups (code, name) VALUES ('4', '4/ Матрица РЫБА-СНЭКИ')
		RETURNING id::text`, &fx.parentGroup)
	mustScan(t, pf.pool, `INSERT INTO nomenclature_groups (code, name, parent_id) VALUES ('4.1', 'Снеки', $1::uuid)
		RETURNING id::text`, &child, fx.parentGroup)
	mustScan(t, pf.pool, `INSERT INTO suppliers (name) VALUES ('Рыбный двор') RETURNING id::text`, &fx.supplier)
	mustScan(t, pf.pool, `INSERT INTO goods (name, uom, group_id, supplier_id, cz_marked)
		VALUES ('Снек', 'шт', $1::uuid, $2::uuid, true) RETURNING id::text`, &fx.good2, child, fx.supplier)
	mustScan(t, pf.pool, `INSERT INTO batches (good_id, production_date) VALUES ($1::uuid, '2026-02-01')
		RETURNING id::text`, &fx.batch2, fx.good2)
	return fx
}

// put кладёт товар в россыпь ячейки строкой склада iwh.
func (fx *stocktakeFixture) put(t *testing.T, cell, good, batch, iwh string, qty int64) {
	t.Helper()
	mustNoErr(t, repository.NewStockRepository(fx.pool).Add(context.Background(), model.StockKey{
		CellID: cell, GoodID: good, BatchID: batch, InternalWarehouseID: iwh,
	}, decimal.NewFromInt(qty)))
}

// box кладёт в ячейку размещённый короб «Основного» с товаром фикстуры: состав и остаток.
func (fx *stocktakeFixture) box(t *testing.T, cell string, qty int64) string {
	t.Helper()
	lu := uuid.NewString()
	ctx := context.Background()
	if _, err := fx.pool.Exec(ctx, `INSERT INTO load_units (id, kind, cell_id, status)
		VALUES ($1::uuid, 'box', $2::uuid, 'placed')`, lu, cell); err != nil {
		t.Fatalf("короб: %v", err)
	}
	if _, err := fx.pool.Exec(ctx, `INSERT INTO lu_content (load_unit_id, good_id, batch_id, qty)
		VALUES ($1::uuid, $2::uuid, $3::uuid, $4)`, lu, fx.good, fx.batch, qty); err != nil {
		t.Fatalf("состав короба: %v", err)
	}
	fx.put(t, cell, fx.good, fx.batch, fx.iwh, qty)
	return lu
}

// mark кладёт марку второго товара россыпью в ячейку (без остатка — его кладёт put).
func (fx *stocktakeFixture) mark(t *testing.T, cell, cis string) {
	t.Helper()
	if _, err := fx.pool.Exec(context.Background(), `
		INSERT INTO cz_marks (cis, good_id, batch_id, cell_id, internal_warehouse_id)
		VALUES ($1, $2::uuid, $3::uuid, $4::uuid, $5::uuid)`, cis, fx.good2, fx.batch2, cell, fx.iwh); err != nil {
		t.Fatalf("марка: %v", err)
	}
}

func (fx *stocktakeFixture) create(kind string, objects ...string) (model.StocktakeCreated, error) {
	return fx.repo.Create(context.Background(), model.StocktakeCreateInput{
		WarehouseID: fx.wh, ScopeKind: kind, ObjectIDs: objects, CreatedBy: fx.user,
	})
}

// cellsOf — ячейки пересчёта по адресу: адрес → id ячейки пересчёта.
func (fx *stocktakeFixture) cellsOf(t *testing.T, stocktakeID string) map[string]string {
	t.Helper()
	rows, err := fx.pool.Query(context.Background(), `
		SELECT c.address, sc.id::text FROM stocktake_cells sc JOIN cells c ON c.id = sc.cell_id
		WHERE sc.stocktake_id = $1::uuid AND sc.status = 'pending'`, stocktakeID)
	mustNoErr(t, err)
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var addr, id string
		mustNoErr(t, rows.Scan(&addr, &id))
		out[addr] = id
	}
	return out
}

// takeBy отдаёт ячейку пересчёта работнику — взятие ячейки приходит с P10-03.
func (fx *stocktakeFixture) takeBy(t *testing.T, stCell, user string) {
	t.Helper()
	if _, err := fx.pool.Exec(context.Background(), `
		UPDATE stocktake_cells SET status = 'taken', taken_by = $2::uuid, taken_at = now()
		WHERE id = $1::uuid`, stCell, user); err != nil {
		t.Fatalf("взять ячейку: %v", err)
	}
}

// marksIn — сколько марок записано в снимок ячейки пересчёта.
func (fx *stocktakeFixture) marksIn(t *testing.T, stCell string) int {
	t.Helper()
	var n int
	mustScanInt(t, fx.putawayFixture, `SELECT count(*) FROM stocktake_marks WHERE stocktake_cell_id = $1::uuid`, &n, stCell)
	return n
}

func (fx *stocktakeFixture) cellStatus(t *testing.T, stCell string) string {
	t.Helper()
	var s string
	mustScan(t, fx.pool, `SELECT status FROM stocktake_cells WHERE id = $1::uuid`, &s, stCell)
	return s
}

// P10-02: область разворачивается в ячейки — каждая своим правилом; ячейка приёмки не входит;
// пересчёт получает одно общее задание в пуле.
func TestStocktake_createExpandsScope(t *testing.T) {
	fx := setupStocktake(t)
	fx.put(t, fx.cellA, fx.good, fx.batch, fx.iwh, 3) // приёмка — не считается
	fx.put(t, fx.cellB, fx.good, fx.batch, fx.iwh, 5)
	fx.put(t, fx.cellC, fx.good2, fx.batch2, fx.iwhDefect, 2)

	for _, c := range []struct {
		name    string
		kind    string
		objects []string
		want    []string
	}{
		{"весь склад — и пустая ячейка", model.StocktakeScopeAll, nil, []string{"B", "C", "D"}},
		{"выбранные ячейки", model.StocktakeScopeCells, []string{fx.cellD}, []string{"D"}},
		{"матрица с поддеревом", model.StocktakeScopeGroup, []string{fx.parentGroup}, []string{"C"}},
		{"поставщик", model.StocktakeScopeSupplier, []string{fx.supplier}, []string{"C"}},
		{"товар", model.StocktakeScopeGood, []string{fx.good}, []string{"B"}},
		{"внутренний склад", model.StocktakeScopeInternalWarehouse, []string{fx.iwhDefect}, []string{"C"}},
	} {
		st, err := fx.create(c.kind, c.objects...)
		if err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		got := fx.cellsOf(t, st.ID)
		if len(got) != len(c.want) || st.Cells != len(c.want) {
			t.Errorf("%s: ячейки %v (Cells=%d), ожидались %v", c.name, got, st.Cells, c.want)
			continue
		}
		for _, addr := range c.want {
			if _, ok := got[addr]; !ok {
				t.Errorf("%s: нет ячейки %s", c.name, addr)
			}
		}
		var kind, status string
		mustScan(t, fx.pool, `SELECT kind FROM warehouse_tasks WHERE id = $1::uuid AND stocktake_id = $2::uuid`,
			&kind, st.TaskID, st.ID)
		mustScan(t, fx.pool, `SELECT status FROM stocktakes WHERE id = $1::uuid`, &status, st.ID)
		if kind != model.TaskStocktake || status != "new" {
			t.Errorf("%s: задание %q, пересчёт %q", c.name, kind, status)
		}
	}
}

// P10-02: неверная область — отказ, и ничего не остаётся: ни документа, ни задания.
func TestStocktake_createRejects(t *testing.T) {
	fx := setupStocktake(t)
	var otherWh, foreignCell string
	mustScan(t, fx.pool, `INSERT INTO warehouses (code, name) VALUES ('WH2', 'другой') RETURNING id::text`, &otherWh)
	mustScan(t, fx.pool, `INSERT INTO cells (warehouse_id, address) VALUES ($1::uuid, 'Z') RETURNING id::text`,
		&foreignCell, otherWh)

	for _, c := range []struct {
		name    string
		kind    string
		objects []string
		want    error
	}{
		{"ячейка приёмки", model.StocktakeScopeCells, []string{fx.cellA}, model.ErrStocktakeReceivingCell},
		{"ячейка другого склада", model.StocktakeScopeCells, []string{foreignCell}, model.ErrStocktakeUnknownObject},
		{"нет такой ячейки", model.StocktakeScopeCells, []string{uuid.NewString()}, model.ErrStocktakeUnknownObject},
		{"нет такой группы", model.StocktakeScopeGroup, []string{uuid.NewString()}, model.ErrStocktakeUnknownObject},
		{"товара нет на полках", model.StocktakeScopeGood, []string{fx.good2}, model.ErrStocktakeNoCells},
	} {
		if _, err := fx.create(c.kind, c.objects...); !errors.Is(err, c.want) {
			t.Errorf("%s: ожидалось %v, получено %v", c.name, c.want, err)
		}
	}
	var n string
	mustScan(t, fx.pool, `SELECT (SELECT count(*) FROM stocktakes) + (SELECT count(*) FROM warehouse_tasks)`, &n)
	if n != "0" {
		t.Errorf("после отказов осталось %s записей пересчёта и заданий", n)
	}
}

// P10-02: снимок снимается при начале подсчёта ячейки — россыпь по складам, короб целиком,
// марки россыпью; повтор снимок не трогает; чужую ячейку начать нельзя.
func TestStocktake_startCountSnapshot(t *testing.T) {
	fx := setupStocktake(t)
	ctx := context.Background()
	lu := fx.box(t, fx.cellB, 12)
	fx.put(t, fx.cellB, fx.good, fx.batch, fx.iwh, 5)
	fx.put(t, fx.cellB, fx.good, fx.batch, fx.iwhDefect, 2)
	fx.put(t, fx.cellB, fx.good2, fx.batch2, fx.iwh, 2)
	fx.mark(t, fx.cellB, "0104600000000017215L1")
	fx.mark(t, fx.cellB, "0104600000000017215L2")

	st, err := fx.create(model.StocktakeScopeCells, fx.cellB)
	mustNoErr(t, err)
	stCell := fx.cellsOf(t, st.ID)["B"]
	other := newUserNamed(t, fx.putawayFixture, "90000088", "Другой")
	if _, err := fx.repo.StartCount(ctx, stCell, fx.user); !errors.Is(err, model.ErrStocktakeCellNotYours) {
		t.Errorf("невзятая ячейка: ожидался ErrStocktakeCellNotYours, получено %v", err)
	}
	fx.takeBy(t, stCell, other)
	if _, err := fx.repo.StartCount(ctx, stCell, fx.user); !errors.Is(err, model.ErrStocktakeCellNotYours) {
		t.Errorf("чужая ячейка: ожидался ErrStocktakeCellNotYours, получено %v", err)
	}
	fx.takeBy(t, stCell, fx.user)

	snap, err := fx.repo.StartCount(ctx, stCell, fx.user)
	mustNoErr(t, err)
	if len(snap.Positions) != 4 || fx.marksIn(t, stCell) != 2 {
		t.Errorf("снимок: позиций %d, марок %d — ожидалось 4 и 2", len(snap.Positions), fx.marksIn(t, stCell))
	}
	for _, p := range snap.Positions {
		if (p.Kind == model.StocktakePositionBox) != (p.LoadUnitID != nil && p.GoodID == nil) {
			t.Errorf("позиция %+v: вид не совпадает с содержимым", p)
		}
	}
	for what, c := range map[string]struct {
		sql  string
		args []any
		want string
	}{
		"россыпь «Основного» — без короба": {`SELECT expected_qty::int::text FROM stocktake_lines
			WHERE stocktake_cell_id = $1::uuid AND good_id = $2::uuid AND load_unit_id IS NULL AND internal_warehouse_id = $3::uuid`,
			[]any{stCell, fx.good, fx.iwh}, "5"},
		"россыпь «Брака» — своей строкой": {`SELECT expected_qty::int::text FROM stocktake_lines
			WHERE stocktake_cell_id = $1::uuid AND good_id = $2::uuid AND internal_warehouse_id = $3::uuid`,
			[]any{stCell, fx.good, fx.iwhDefect}, "2"},
		"короб целиком": {`SELECT expected_qty::int::text FROM stocktake_lines
			WHERE stocktake_cell_id = $1::uuid AND load_unit_id = $2::uuid AND good_id IS NULL`,
			[]any{stCell, lu}, "1"},
		"марки ожидаются на строке своей позиции": {`SELECT count(*)::text FROM stocktake_marks m
			JOIN stocktake_lines l ON l.id = m.line_id AND l.good_id = $2::uuid
			WHERE m.stocktake_cell_id = $1::uuid AND m.expected AND NOT m.found`,
			[]any{stCell, fx.good2}, "2"},
		"ячейка на подсчёте": {`SELECT status FROM stocktake_cells WHERE id = $1::uuid AND started_at IS NOT NULL`,
			[]any{stCell}, "counting"},
		"пересчёт в работе": {`SELECT status FROM stocktakes WHERE id = $1::uuid`, []any{st.ID}, "in_progress"},
	} {
		var got string
		mustScan(t, fx.pool, c.sql, &got, c.args...)
		if got != c.want {
			t.Errorf("%s: %s, ожидалось %s", what, got, c.want)
		}
	}

	// Повтор (операция ушла второй раз) снимок не пересоздаёт.
	var lineID, again string
	mustScan(t, fx.pool, `SELECT min(id::text) FROM stocktake_lines WHERE stocktake_cell_id = $1::uuid`, &lineID, stCell)
	if snap2, err := fx.repo.StartCount(ctx, stCell, fx.user); err != nil || len(snap2.Positions) != len(snap.Positions) {
		t.Errorf("повтор: %+v, %v — ожидалось %d позиций", snap2, err, len(snap.Positions))
	}
	mustScan(t, fx.pool, `SELECT min(id::text) FROM stocktake_lines WHERE stocktake_cell_id = $1::uuid`, &again, stCell)
	if again != lineID {
		t.Error("повтор пересоздал строки снимка")
	}
}

// P10-02: область по товару снимает в ячейке только свой товар; короб без товара области не
// трогается.
func TestStocktake_snapshotAreaGoodsOnly(t *testing.T) {
	fx := setupStocktake(t)
	fx.box(t, fx.cellB, 12)
	fx.put(t, fx.cellB, fx.good, fx.batch, fx.iwh, 5)
	fx.put(t, fx.cellB, fx.good2, fx.batch2, fx.iwh, 1)
	fx.mark(t, fx.cellB, "0104600000000017215L1")

	st, err := fx.create(model.StocktakeScopeSupplier, fx.supplier)
	mustNoErr(t, err)
	stCell := fx.cellsOf(t, st.ID)["B"]
	fx.takeBy(t, stCell, fx.user)
	snap, err := fx.repo.StartCount(context.Background(), stCell, fx.user)
	mustNoErr(t, err)
	if len(snap.Positions) != 1 || fx.marksIn(t, stCell) != 1 {
		t.Errorf("снимок по поставщику: позиций %d, марок %d — ожидалось 1 и 1", len(snap.Positions), fx.marksIn(t, stCell))
	}
	var foreign string
	mustScan(t, fx.pool, `SELECT count(*)::text FROM stocktake_lines
		WHERE stocktake_cell_id = $1::uuid AND (good_id IS DISTINCT FROM $2::uuid)`, &foreign, stCell, fx.good2)
	if foreign != "0" {
		t.Errorf("в снимок попало %s строк не своего товара", foreign)
	}
}

// P10-02: движение через ячейку на подсчёте сбивает его — остаток, состав и место короба,
// марка; движение в другой ячейке не трогает. Сбитую ячейку начинают заново — снимок свежий.
func TestStocktake_movementDisruptsCount(t *testing.T) {
	fx := setupStocktake(t)
	ctx := context.Background()
	lu := fx.box(t, fx.cellB, 12)
	fx.put(t, fx.cellB, fx.good, fx.batch, fx.iwh, 5)
	fx.put(t, fx.cellC, fx.good2, fx.batch2, fx.iwh, 1)
	fx.mark(t, fx.cellC, "0104600000000017215L1")

	st, err := fx.create(model.StocktakeScopeCells, fx.cellB, fx.cellD)
	mustNoErr(t, err)
	cells := fx.cellsOf(t, st.ID)
	stB, stD := cells["B"], cells["D"]
	start := func(stCell string) {
		t.Helper()
		fx.takeBy(t, stCell, fx.user)
		if _, err := fx.repo.StartCount(ctx, stCell, fx.user); err != nil {
			t.Fatalf("начать подсчёт: %v", err)
		}
	}
	restart := func(stCell string) {
		t.Helper()
		if _, err := fx.repo.StartCount(ctx, stCell, fx.user); err != nil {
			t.Fatalf("начать подсчёт заново: %v", err)
		}
	}
	start(stB)
	start(stD)

	fx.put(t, fx.cellC, fx.good2, fx.batch2, fx.iwh, 1)
	if s := fx.cellStatus(t, stB); s != "counting" {
		t.Errorf("движение в другой ячейке сбило подсчёт: %s", s)
	}

	for _, c := range []struct {
		what, stCell, sql string
		args              []any
	}{
		{"остаток", stB, `UPDATE stock SET qty = qty + 1 WHERE cell_id = $1::uuid AND good_id = $2::uuid
			AND internal_warehouse_id = $3::uuid`, []any{fx.cellB, fx.good, fx.iwh}},
		{"состав короба", stB, `UPDATE lu_content SET qty = qty - 1 WHERE load_unit_id = $1::uuid`, []any{lu}},
		{"короб уехал в другую ячейку", stB, `UPDATE load_units SET cell_id = $2::uuid WHERE id = $1::uuid`,
			[]any{lu, fx.cellC}},
		{"короб приехал в ячейку", stD, `UPDATE load_units SET cell_id = $2::uuid WHERE id = $1::uuid`,
			[]any{lu, fx.cellD}},
		{"марка легла в ячейку", stD, `UPDATE cz_marks SET cell_id = $2::uuid WHERE cis = $1`,
			[]any{"0104600000000017215L1", fx.cellD}},
	} {
		if _, err := fx.pool.Exec(ctx, c.sql, c.args...); err != nil {
			t.Fatalf("%s: %v", c.what, err)
		}
		if s := fx.cellStatus(t, c.stCell); s != "disrupted" {
			t.Errorf("%s: ячейка %s, ожидалось disrupted", c.what, s)
		}
		restart(c.stCell)
	}

	// Свежий снимок: в D теперь короб и марка с нулём россыпи — учёт её остатка остался в C.
	var expectedBox string
	mustScan(t, fx.pool, `SELECT count(*)::text FROM stocktake_lines WHERE stocktake_cell_id = $1::uuid
		AND load_unit_id = $2::uuid`, &expectedBox, stD, lu)
	if expectedBox != "1" {
		t.Errorf("после перезапуска короба нет в снимке D")
	}
}

// P10-02: начало подсчёта ждёт идущее движение ячейки и видит его результат — иначе движение
// не попало бы ни в снимок, ни под пометку «сбит».
func TestStocktake_startCountWaitsForMovement(t *testing.T) {
	fx := setupStocktake(t)
	ctx := context.Background()
	fx.put(t, fx.cellB, fx.good, fx.batch, fx.iwh, 5)
	st, err := fx.create(model.StocktakeScopeCells, fx.cellB)
	mustNoErr(t, err)
	stCell := fx.cellsOf(t, st.ID)["B"]
	fx.takeBy(t, stCell, fx.user)

	tx, err := fx.pool.Begin(ctx)
	mustNoErr(t, err)
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `UPDATE stock SET qty = 7 WHERE cell_id = $1::uuid`, fx.cellB); err != nil {
		t.Fatalf("движение: %v", err)
	}

	done := make(chan error, 1)
	go func() {
		_, err := fx.repo.StartCount(ctx, stCell, fx.user)
		done <- err
	}()
	select {
	case err := <-done:
		t.Fatalf("подсчёт начался, не дождавшись движения: %v", err)
	case <-time.After(300 * time.Millisecond):
	}
	mustNoErr(t, tx.Commit(ctx))
	mustNoErr(t, <-done)

	var expected string
	mustScan(t, fx.pool, `SELECT expected_qty::int::text FROM stocktake_lines WHERE stocktake_cell_id = $1::uuid`,
		&expected, stCell)
	if expected != "7" || fx.cellStatus(t, stCell) != "counting" {
		t.Errorf("снимок %s, ячейка %s — ожидалось 7 и counting", expected, fx.cellStatus(t, stCell))
	}
}
