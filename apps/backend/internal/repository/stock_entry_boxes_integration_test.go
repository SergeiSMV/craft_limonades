package repository_test

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// Тесты ADHOC-46: короба с QR, короба ЧЗ и марки во «Вводе остатков». Критерий - после финала
// короба лежат в своих ячейках, марки - в коробах или россыпью, остаток грани сходится с
// россыпью и составом коробов; отказ строки не меняет ничего.

// entryFixture - фикстура прохода: склад перемещения (A, B, C, ячейка приёмки R) и сессия.
type entryFixture struct {
	*moveFixture
	repo    *repository.StockEntryRepository
	session string
}

func setupEntry(t *testing.T) *entryFixture {
	t.Helper()
	ef := &entryFixture{moveFixture: setupMove(t)}
	ef.repo = repository.NewStockEntryRepository(ef.pool)
	ef.session = ef.newSession(t)
	// GTIN марок фикстуры (`04600000000017`) - ШК товара: проводка сверяет марку с товаром строки.
	if _, err := ef.pool.Exec(context.Background(),
		`INSERT INTO barcodes (good_id, barcode) VALUES ($1::uuid, '4600000000017')`, ef.good); err != nil {
		t.Fatalf("ШК товара: %v", err)
	}
	return ef
}

func (ef *entryFixture) newSession(t *testing.T) string {
	t.Helper()
	id, err := ef.repo.CreateWithID(context.Background(), uuid.NewString(), ef.wh, ef.user)
	mustNoErr(t, err)
	return id
}

// line - строка товара фикстуры партии 2026-01-01; марки - её единицы.
func entryLine(good string, qty int64, lu string, marks ...string) repository.StockEntryLineInput {
	ln := repository.StockEntryLineInput{
		GoodID: good, ProductionDate: "2026-01-01", Qty: decimal.NewFromInt(qty), LoadUnitID: lu,
	}
	for _, cis := range marks {
		ln.Marks = append(ln.Marks, model.ReceiptMark{CIS: cis})
	}
	return ln
}

func (ef *entryFixture) checkpoint(t *testing.T, in repository.StockEntryCellInput) error {
	t.Helper()
	return ef.repo.Checkpoint(context.Background(), ef.session, in)
}

func (ef *entryFixture) count(t *testing.T, sql string, args ...any) string {
	t.Helper()
	var n string
	mustScan(t, ef.pool, sql, &n, args...)
	return n
}

// Свой короб и россыпь в ячейке, где уже лежит короб: остаток грани - россыпь + новый короб +
// состав лежавшего; новый короб размещён с источником «ввод остатков».
func TestStockEntry_boxAndLoose(t *testing.T) {
	ef := setupEntry(t)
	_, boxB := ef.twoBoxes(t) // в B уже лежит короб boxB: 12 шт партии 2026-01-01
	box := uuid.NewString()

	if err := ef.checkpoint(t, repository.StockEntryCellInput{
		CellID:    ef.cellB,
		LoadUnits: []repository.LoadUnitInput{{ID: box, Kind: model.LoadUnitBox}},
		Lines:     []repository.StockEntryLineInput{entryLine(ef.good, 3, ""), entryLine(ef.good, 4, box)},
	}); err != nil {
		t.Fatalf("checkpoint: %v", err)
	}
	written, err := ef.repo.Finalize(context.Background(), ef.session)
	if err != nil {
		t.Fatalf("финал: %v", err)
	}
	if written != 1 {
		t.Fatalf("граней: %d, ждали 1 (россыпь и короб - одна грань)", written)
	}
	if got := ef.qtyOf(t, ef.cellB, ef.batch); got != "19" {
		t.Fatalf("остаток B: %s, ждали 3 + 4 + 12 = 19", got)
	}
	if got := currentCell(t, ef.stockFixture, box); got != ef.cellB {
		t.Fatalf("короб не в B: %s", got)
	}
	if got := ef.count(t, `SELECT qty::int::text FROM lu_content WHERE load_unit_id = $1::uuid`, box); got != "4" {
		t.Fatalf("состав короба: %s", got)
	}
	if got := ef.count(t, `SELECT source FROM placements WHERE load_unit_id = $1::uuid`, box); got != model.PlacementStockEntry {
		t.Fatalf("источник размещения: %s", got)
	}
	// Лежавший короб не тронут.
	if got := ef.count(t, `SELECT qty::int::text FROM lu_content WHERE load_unit_id = $1::uuid`, boxB); got != "12" {
		t.Fatalf("состав лежавшего короба: %s", got)
	}
	// Документ - одна строка грани.
	if got := ef.count(t, `
		SELECT jsonb_array_length(snapshot->'rows')::text FROM report_documents WHERE source_id = $1::uuid`,
		ef.session); got != "1" {
		t.Fatalf("строк документа: %s", got)
	}
}

// Короб ЧЗ с упаковкой и марки россыпью, одна с расхождением: марки на местах, агрегаты
// заведены, товар маркируемый, марка с расхождением - проблемой в «Изоляторе».
func TestStockEntry_czBoxAndMarks(t *testing.T) {
	ef := setupEntry(t)
	box := uuid.NewString()
	in := repository.StockEntryCellInput{
		CellID:    ef.cellC,
		LoadUnits: []repository.LoadUnitInput{{ID: box, Kind: model.LoadUnitBox, CZCode: czBox}},
		CZGroups:  []model.CZAggregate{{Code: czGroup, Kind: model.CZAggregateGroup, ParentCode: czBox}},
		Lines: []repository.StockEntryLineInput{
			entryLine(ef.good, 3, box, czG1, czG2, czB1),
			entryLine(ef.good, 2, "", czLoose[0], czLoose[1]),
		},
	}
	in.Lines[0].Marks[0].AggregateCode = czGroup
	in.Lines[0].Marks[1].AggregateCode = czGroup
	in.Lines[0].Marks[2].AggregateCode = czBox
	in.Lines[1].Marks[1].Discrepancy = model.CZDiscrepancyForeignMark
	if err := ef.checkpoint(t, in); err != nil {
		t.Fatalf("checkpoint: %v", err)
	}
	if _, err := ef.repo.Finalize(context.Background(), ef.session); err != nil {
		t.Fatalf("финал: %v", err)
	}

	cf := &czMoveFixture{moveFixture: ef.moveFixture}
	for _, cis := range []string{czG1, czG2, czB1} {
		if got := cf.placeOf(t, cis); got != "lu:"+box {
			t.Fatalf("марка %s: %s, ждали в коробе", cis, got)
		}
	}
	if got := cf.placeOf(t, czLoose[0]); got != "cell:"+ef.cellC {
		t.Fatalf("марка россыпи: %s", got)
	}
	if got := ef.count(t, `SELECT load_unit_id::text FROM cz_aggregates WHERE code = $1`, czBox); got != box {
		t.Fatalf("короб ЧЗ не связан с ГЕ: %s", got)
	}
	if got := ef.count(t, `SELECT cz_marked::text FROM goods WHERE id = $1::uuid`, ef.good); got != "true" {
		t.Fatal("товар не стал маркируемым")
	}
	// Остаток C на «Основном»: 3 в коробе + 1 россыпью; одна марка - в «Изоляторе».
	if got := ef.qtyOf(t, ef.cellC, ef.batch); got != "4" {
		t.Fatalf("остаток C: %s, ждали 4", got)
	}
	if got := ef.count(t, `
		SELECT count(*)::text FROM warehouse_problems p
		JOIN internal_warehouses w ON w.id = p.to_internal_warehouse_id
		WHERE w.code = 'ISOLATOR' AND p.reason = 'foreign_mark'`); got != "1" {
		t.Fatalf("проблем в «Изоляторе»: %s", got)
	}
}

// Отказы строк: все плохие строки ячейки названы сразу, в сессию ничего не попало.
func TestStockEntry_rejections(t *testing.T) {
	ef := setupEntry(t)
	cf := setupCZMoveOn(t, ef) // короб ЧЗ boxA в A, марки россыпью в A, товар маркируемый
	empty := uuid.NewString()

	err := ef.checkpoint(t, repository.StockEntryCellInput{
		CellID: ef.cellA,
		LoadUnits: []repository.LoadUnitInput{
			{ID: cf.boxB, Kind: model.LoadUnitBox}, // короб уже на складе
			{ID: empty, Kind: model.LoadUnitBox},   // короб без товара
		},
		Lines: []repository.StockEntryLineInput{
			entryLine(ef.good, 1, cf.boxB, "0104600000000017215N1"),
			entryLine(ef.good, 2, ""),                          // маркируемый без марок
			entryLine(ef.good, 1, "", czLoose[0]),              // марка уже в учёте
			entryLine(ef.good, 2, "", "0104600000000017215N2"), // марок меньше единиц
		},
	})
	var lines *model.DocumentLinesError
	if !errors.As(err, &lines) {
		t.Fatalf("ждали отказ строк, получили %v", err)
	}
	want := []error{
		model.ErrLoadUnitExists, model.ErrEntryEmptyBox,
		model.ErrEntryCellHasMarks, model.ErrCZMarksRequired, model.ErrCZMarkExists,
		model.ErrCZMarksQtyMismatch,
	}
	for _, w := range want {
		if !errors.Is(err, w) {
			t.Errorf("нет причины %v в %v", w, err)
		}
	}
	if got := ef.count(t, `SELECT count(*)::text FROM stock_entry_lines WHERE session_id = $1::uuid`, ef.session); got != "0" {
		t.Fatalf("строк в сессии после отказа: %s", got)
	}
	if !strings.Contains(err.Error(), "марка уже есть в учёте склада") {
		t.Fatalf("причина не по-русски: %v", err)
	}
}

// Повтор того же короба и марки в другой ячейке прохода - отказ; повторный checkpoint ячейки
// заменяет её: убранный короб на финале не появляется.
func TestStockEntry_cellReplacedAndDuplicates(t *testing.T) {
	ef := setupEntry(t)
	box := uuid.NewString()
	withBox := repository.StockEntryCellInput{
		CellID:    ef.cellB,
		LoadUnits: []repository.LoadUnitInput{{ID: box, Kind: model.LoadUnitBox}},
		Lines:     []repository.StockEntryLineInput{entryLine(ef.good, 5, box)},
	}
	mustNoErr(t, ef.checkpoint(t, withBox))

	dup := withBox
	dup.CellID = ef.cellC
	if err := ef.checkpoint(t, dup); !errors.Is(err, model.ErrEntryDuplicate) {
		t.Fatalf("короб в двух ячейках: %v", err)
	}

	// Та же ячейка ещё раз - уже без короба.
	mustNoErr(t, ef.checkpoint(t, repository.StockEntryCellInput{
		CellID: ef.cellB,
		Lines:  []repository.StockEntryLineInput{entryLine(ef.good, 2, "")},
	}))
	if _, err := ef.repo.Finalize(context.Background(), ef.session); err != nil {
		t.Fatalf("финал: %v", err)
	}
	if got := ef.count(t, `SELECT count(*)::text FROM load_units WHERE id = $1::uuid`, box); got != "0" {
		t.Fatal("убранный короб заведён на финале")
	}
	if got := ef.qtyOf(t, ef.cellB, ef.batch); got != "2" {
		t.Fatalf("остаток B: %s", got)
	}
}

// Короб или марку, введённые проходом, между checkpoint и финалом завела приёмка - финал
// отказывает и ничего не проводит.
func TestStockEntry_finalizeRechecks(t *testing.T) {
	ef := setupEntry(t)
	box := uuid.NewString()
	mustNoErr(t, ef.checkpoint(t, repository.StockEntryCellInput{
		CellID:    ef.cellB,
		LoadUnits: []repository.LoadUnitInput{{ID: box, Kind: model.LoadUnitBox}},
		Lines:     []repository.StockEntryLineInput{entryLine(ef.good, 5, box)},
	}))
	// Тот же короб завела приёмка (ГЕ с этим id уже на складе).
	if _, err := ef.pool.Exec(context.Background(),
		`INSERT INTO load_units (id, kind) VALUES ($1::uuid, 'box')`, box); err != nil {
		t.Fatalf("короб приёмки: %v", err)
	}

	_, err := ef.repo.Finalize(context.Background(), ef.session)
	if !errors.Is(err, model.ErrLoadUnitExists) {
		t.Fatalf("финал: %v", err)
	}
	if got := ef.count(t, `SELECT status FROM stock_entry_sessions WHERE id = $1::uuid`, ef.session); got != "draft" {
		t.Fatalf("сессия после отказа финала: %s", got)
	}
}

// Долг 33: короб ЧЗ в причине отказа строки движения подписан кодом ЧЗ, как на ТСД.
func TestLineRejection_czBoxLabel(t *testing.T) {
	cf := setupCZMove(t)
	_, err := cf.move(t, uuid.NewString(), luTo(cf.boxA, cf.cellA))
	if err == nil || !strings.Contains(err.Error(), "короб ЧЗ 0000 0017") {
		t.Fatalf("подпись короба ЧЗ: %v", err)
	}
}

// setupCZMoveOn - марки фикстуры CZ-06 поверх фикстуры прохода (тот же склад и товар).
func setupCZMoveOn(t *testing.T, ef *entryFixture) *czMoveFixture {
	t.Helper()
	cf := &czMoveFixture{moveFixture: ef.moveFixture}
	cf.boxA, cf.boxB = ef.twoBoxes(t)
	ctx := context.Background()
	for _, sql := range []struct {
		q    string
		args []any
	}{
		{`UPDATE goods SET cz_marked = true WHERE id = $1::uuid`, []any{ef.good}},
		{`INSERT INTO cz_aggregates (code, kind, load_unit_id) VALUES ($1, 'BOX', $2::uuid)`, []any{czBox, cf.boxA}},
		{`INSERT INTO cz_marks (cis, good_id, batch_id, cell_id, internal_warehouse_id)
		  VALUES ($1, $2::uuid, $3::uuid, $4::uuid, $5::uuid)`,
			[]any{czLoose[0], ef.good, ef.batch, ef.cellA, ef.iwh}},
	} {
		if _, err := ef.pool.Exec(ctx, sql.q, sql.args...); err != nil {
			t.Fatalf("фикстура марок: %v", err)
		}
	}
	return cf
}
