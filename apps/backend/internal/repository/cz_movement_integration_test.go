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

// Тесты CZ-06: марки ЧЗ при перемещении и размещении. Критерий задачи - на любой момент
// известно, где лежит каждая марка и вскрыт ли агрегат.

// Коды фикстуры марок: короб ЧЗ, групповая упаковка в нём, марки в упаковке (g1, g2), марка
// прямо в коробе (b1) и пять марок россыпью в ячейке A.
const (
	czBox   = "00046000000000000017"
	czGroup = "0104600000000017216GRP"
	czG1    = "0104600000000017215G1"
	czG2    = "0104600000000017215G2"
	czB1    = "0104600000000017215B1"
)

var czLoose = []string{
	"0104600000000017215L1", "0104600000000017215L2", "0104600000000017215L3",
	"0104600000000017215L4", "0104600000000017215L5",
}

// czMoveFixture - фикстура перемещения (twoBoxes): короб boxA в A - короб ЧЗ с марками, boxB
// в B - свой короб с QR; товар маркируемый.
type czMoveFixture struct {
	*moveFixture
	boxA, boxB string
}

func setupCZMove(t *testing.T) *czMoveFixture {
	t.Helper()
	mf := setupMove(t)
	boxA, boxB := mf.twoBoxes(t)
	ctx := context.Background()
	for _, sql := range []struct {
		q    string
		args []any
	}{
		{`UPDATE goods SET cz_marked = true WHERE id = $1::uuid`, []any{mf.good}},
		{`INSERT INTO cz_aggregates (code, kind, load_unit_id) VALUES ($1, 'BOX', $2::uuid)`, []any{czBox, boxA}},
		{`INSERT INTO cz_aggregates (code, kind, parent_code) VALUES ($1, 'GROUP', $2)`, []any{czGroup, czBox}},
		{`INSERT INTO cz_marks (cis, good_id, batch_id, load_unit_id, aggregate_code)
		  VALUES ($1, $4::uuid, $5::uuid, $6::uuid, $7), ($2, $4::uuid, $5::uuid, $6::uuid, $7),
		         ($3, $4::uuid, $5::uuid, $6::uuid, $8)`,
			[]any{czG1, czG2, czB1, mf.good, mf.batch, boxA, czGroup, czBox}},
	} {
		if _, err := mf.pool.Exec(ctx, sql.q, sql.args...); err != nil {
			t.Fatalf("фикстура марок: %v", err)
		}
	}
	for _, cis := range czLoose {
		if _, err := mf.pool.Exec(ctx, `
			INSERT INTO cz_marks (cis, good_id, batch_id, cell_id, internal_warehouse_id)
			VALUES ($1, $2::uuid, $3::uuid, $4::uuid, $5::uuid)`,
			cis, mf.good, mf.batch, mf.cellA, mf.iwh); err != nil {
			t.Fatalf("марка россыпи: %v", err)
		}
	}
	return &czMoveFixture{moveFixture: mf, boxA: boxA, boxB: boxB}
}

// markLine - строка товара фикстуры с марками: количество - их число.
func (cf *czMoveFixture) markLine(fromCell, fromLU, toCell, toLU string, marks ...string) repository.MovementLineInput {
	ln := cf.goodsLine(int64(len(marks)), fromCell, fromLU, toCell, toLU)
	ln.Marks = marks
	return ln
}

// placeOf - где лежит марка: «lu:<id>» в коробе, «cell:<id>» россыпью, «нет» - не на складе.
func (cf *czMoveFixture) placeOf(t *testing.T, cis string) string {
	t.Helper()
	var p string
	mustScan(t, cf.pool, `
		SELECT CASE WHEN status <> 'in_stock' THEN 'нет'
		            WHEN load_unit_id IS NOT NULL THEN 'lu:' || load_unit_id::text
		            ELSE 'cell:' || cell_id::text END
		FROM cz_marks WHERE cis = $1`, &p, cis)
	return p
}

// opened - вскрыт ли агрегат ЧЗ.
func (cf *czMoveFixture) opened(t *testing.T, code string) bool {
	t.Helper()
	var o string
	mustScan(t, cf.pool, `SELECT (opened_at IS NOT NULL)::text FROM cz_aggregates WHERE code = $1`, &o, code)
	return o == "true"
}

// lineErr - причина отказа единственной плохой строки документа.
func lineErr(t *testing.T, err error) error {
	t.Helper()
	var lines *repository.DocumentLinesError
	if !errors.As(err, &lines) || len(lines.Lines) != 1 {
		t.Fatalf("ждали отказ одной строки, получили %v", err)
	}
	return lines.Lines[0].Err
}

// Маркируемый товар без марок не двигается; марок не столько, сколько единиц, марка не из
// источника, чужая партия - отказ строки, и ничего не меняется.
func TestCZMove_rejectsWithoutProperMarks(t *testing.T) {
	cf := setupCZMove(t)

	_, err := cf.move(t, uuid.NewString(), cf.goodsLine(2, cf.cellA, "", cf.cellC, ""))
	if !errors.Is(lineErr(t, err), model.ErrCZMarksRequired) {
		t.Errorf("без марок: %v", err)
	}

	ln := cf.markLine(cf.cellA, "", cf.cellC, "", czLoose[0])
	ln.Qty = decimal.NewFromInt(2)
	if _, err := cf.move(t, uuid.NewString(), ln); !errors.Is(lineErr(t, err), model.ErrCZMarksQtyMismatch) {
		t.Errorf("марок меньше количества: %v", err)
	}

	// Марка короба - не россыпь ячейки.
	_, err = cf.move(t, uuid.NewString(), cf.markLine(cf.cellA, "", cf.cellC, "", czB1))
	if !errors.Is(lineErr(t, err), model.ErrCZMarkNotAtSource) {
		t.Errorf("марка не из источника: %v", err)
	}
	_, err = cf.move(t, uuid.NewString(), cf.markLine(cf.cellA, "", cf.cellC, "", "0104600000000017215XX"))
	if !errors.Is(lineErr(t, err), model.ErrCZMarkNotAtSource) {
		t.Errorf("незнакомая марка: %v", err)
	}

	ln = cf.markLine(cf.cellA, "", cf.cellC, "", czLoose[0])
	ln.ProductionDate = "2026-02-01"
	if _, err := cf.move(t, uuid.NewString(), ln); err == nil {
		t.Error("марка чужой партии прошла")
	}

	if got := cf.placeOf(t, czLoose[0]); got != "cell:"+cf.cellA {
		t.Errorf("марка после отказов: %s, ожидалась россыпь A", got)
	}
}

// Россыпь марками: марки переезжают туда же, куда остаток; из короба в короб - в короб.
func TestCZMove_marksFollowLooseGoods(t *testing.T) {
	cf := setupCZMove(t)

	if _, err := cf.move(t, uuid.NewString(),
		cf.markLine(cf.cellA, "", cf.cellC, "", czLoose[0], czLoose[1]),
		cf.markLine(cf.cellA, "", "", cf.boxB, czLoose[2]),
		// Та же марка дальше в том же документе: C → короб B.
		cf.markLine(cf.cellC, "", "", cf.boxB, czLoose[1]),
	); err != nil {
		t.Fatalf("перемещение марками: %v", err)
	}
	for cis, want := range map[string]string{
		czLoose[0]: "cell:" + cf.cellC,
		czLoose[1]: "lu:" + cf.boxB,
		czLoose[2]: "lu:" + cf.boxB,
		czLoose[3]: "cell:" + cf.cellA,
	} {
		if got := cf.placeOf(t, cis); got != want {
			t.Errorf("марка %s: %s, ожидалось %s", cis, got, want)
		}
	}
	if a, c := cf.qtyOf(t, cf.cellA, cf.batch), cf.qtyOf(t, cf.cellC, cf.batch); a != "14" || c != "1" {
		t.Errorf("остаток A=%s C=%s, ожидалось 14 и 1", a, c)
	}
}

// Вскрытие: марка, вынутая из групповой упаковки, вскрывает и упаковку, и короб ЧЗ; упаковка,
// вынутая целиком, остаётся целой, а короб - вскрыт. Перенос короба целиком ничего не вскрывает
// и марки внутри не трогает.
func TestCZMove_openingAggregates(t *testing.T) {
	t.Run("короб целиком", func(t *testing.T) {
		cf := setupCZMove(t)
		if _, err := cf.move(t, uuid.NewString(), luTo(cf.boxA, cf.cellC)); err != nil {
			t.Fatalf("перенос короба ЧЗ: %v", err)
		}
		if cf.opened(t, czBox) || cf.opened(t, czGroup) {
			t.Error("перенос короба целиком вскрыл агрегат")
		}
		if got := cf.placeOf(t, czG1); got != "lu:"+cf.boxA {
			t.Errorf("марка короба: %s", got)
		}
	})

	t.Run("упаковка целиком", func(t *testing.T) {
		cf := setupCZMove(t)
		if _, err := cf.move(t, uuid.NewString(), cf.markLine("", cf.boxA, cf.cellA, "", czG1, czG2)); err != nil {
			t.Fatalf("упаковка из короба: %v", err)
		}
		if !cf.opened(t, czBox) {
			t.Error("короб ЧЗ не вскрыт, хотя упаковку из него вынули")
		}
		if cf.opened(t, czGroup) {
			t.Error("упаковка вскрыта, хотя переехала целиком")
		}
		if got := cf.luQty(t, cf.boxA); got != "10.000" {
			t.Errorf("в коробе %s, ожидалось 10", got)
		}
	})

	t.Run("бутылка из упаковки", func(t *testing.T) {
		cf := setupCZMove(t)
		if _, err := cf.move(t, uuid.NewString(), cf.markLine("", cf.boxA, "", cf.boxB, czG1)); err != nil {
			t.Fatalf("марка из упаковки: %v", err)
		}
		if !cf.opened(t, czGroup) || !cf.opened(t, czBox) {
			t.Error("упаковка и короб должны быть вскрыты")
		}
		if got := cf.placeOf(t, czG1); got != "lu:"+cf.boxB {
			t.Errorf("марка: %s", got)
		}
	})
}

// Размещение россыпи маркируемого товара - только марками, марки уходят из ячейки приёмки
// в ячейку хранения.
func TestCZPutaway_looseByMarks(t *testing.T) {
	pf := setupPutaway(t)
	task := pf.receive(t, nil, 3)
	ctx := context.Background()
	if _, err := pf.pool.Exec(ctx, `UPDATE goods SET cz_marked = true WHERE id = $1::uuid`, pf.good); err != nil {
		t.Fatal(err)
	}
	for _, cis := range czLoose[:3] {
		if _, err := pf.pool.Exec(ctx, `
			INSERT INTO cz_marks (cis, good_id, batch_id, cell_id, internal_warehouse_id)
			VALUES ($1, $2::uuid, $3::uuid, $4::uuid, $5::uuid)`,
			cis, pf.good, pf.batch, pf.cellA, pf.iwh); err != nil {
			t.Fatal(err)
		}
	}

	if _, err := pf.submit(t, task, uuid.NewString(), looseTo(pf.good, 2, pf.cellB)); !errors.Is(err, model.ErrCZMarksRequired) {
		t.Fatalf("размещение без марок: %v", err)
	}
	ln := looseTo(pf.good, 2, pf.cellB)
	ln.Marks = czLoose[:2]
	if _, err := pf.submit(t, task, uuid.NewString(), ln); err != nil {
		t.Fatalf("размещение марками: %v", err)
	}
	var where string
	mustScan(t, pf.pool, `SELECT string_agg(cell_id::text, ',' ORDER BY cis) FROM cz_marks WHERE cis = ANY($1)`,
		&where, czLoose[:3])
	if want := pf.cellB + "," + pf.cellB + "," + pf.cellA; where != want {
		t.Errorf("ячейки марок %s, ожидалось %s", where, want)
	}
}
