package movement

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/shopspring/decimal"
)

// fakeContents — состав ГЕ из памяти; считает обращения, чтобы проверить чтение одним махом.
type fakeContents struct {
	byID  map[string][]ContentLine
	calls int
	asked []string
}

func (f *fakeContents) Contents(_ context.Context, ids []string) (map[string][]ContentLine, error) {
	f.calls++
	f.asked = append(f.asked, ids...)
	out := map[string][]ContentLine{}
	for _, id := range ids {
		if c, ok := f.byID[id]; ok {
			out[id] = c
		}
	}
	return out, nil
}

func d(v int64) decimal.Decimal { return decimal.NewFromInt(v) }

func line(good, batch string, qty int64) ContentLine {
	return ContentLine{GoodID: good, BatchID: batch, Qty: d(qty)}
}

// Три короба одного товара одной партии в одну ячейку — одна строка: 1С короба не различает.
func TestExpand_boxesAggregateByGoodBatchCells(t *testing.T) {
	fc := &fakeContents{byID: map[string][]ContentLine{
		"lu1": {line("g1", "b1", 12)},
		"lu2": {line("g1", "b1", 12)},
		"lu3": {line("g1", "b1", 12), line("g2", "b2", 3)},
	}}
	moves := []Move{
		{ToCellID: "c1", LoadUnitID: "lu1"},
		{ToCellID: "c1", LoadUnitID: "lu2"},
		{ToCellID: "c1", LoadUnitID: "lu3"},
	}
	got, err := Expand(context.Background(), moves, fc)
	if err != nil {
		t.Fatal(err)
	}
	want := []Line{
		{GoodID: "g1", BatchID: "b1", ToCellID: "c1", Qty: d(36)},
		{GoodID: "g2", BatchID: "b2", ToCellID: "c1", Qty: d(3)},
	}
	assertLines(t, got, want)
	if fc.calls != 1 {
		t.Fatalf("состав читается одним обращением на все ГЕ, а не по одной: обращений %d", fc.calls)
	}
}

// Россыпь проходит как есть и складывается с составом коробов той же грани.
func TestExpand_looseMixedWithBoxes(t *testing.T) {
	fc := &fakeContents{byID: map[string][]ContentLine{"lu1": {line("g1", "b1", 10)}}}
	moves := []Move{
		{ToCellID: "c1", GoodID: "g1", BatchID: "b1", Qty: d(5)},
		{ToCellID: "c1", LoadUnitID: "lu1"},
		{ToCellID: "c2", GoodID: "g1", BatchID: "b1", Qty: d(1)}, // другая ячейка — своя строка
	}
	got, err := Expand(context.Background(), moves, fc)
	if err != nil {
		t.Fatal(err)
	}
	assertLines(t, got, []Line{
		{GoodID: "g1", BatchID: "b1", ToCellID: "c1", Qty: d(15)},
		{GoodID: "g1", BatchID: "b1", ToCellID: "c2", Qty: d(1)},
	})
}

// Разные партии одного товара и разные ячейки-отправители не склеиваются.
func TestExpand_batchesAndSourcesKeptApart(t *testing.T) {
	fc := &fakeContents{byID: map[string][]ContentLine{
		"lu1": {line("g1", "b1", 4), line("g1", "b2", 6)},
	}}
	moves := []Move{
		{FromCellID: "a", ToCellID: "c", LoadUnitID: "lu1"},
		{FromCellID: "b", ToCellID: "c", GoodID: "g1", BatchID: "b1", Qty: d(1)},
	}
	got, err := Expand(context.Background(), moves, fc)
	if err != nil {
		t.Fatal(err)
	}
	assertLines(t, got, []Line{
		{GoodID: "g1", BatchID: "b1", FromCellID: "a", ToCellID: "c", Qty: d(4)},
		{GoodID: "g1", BatchID: "b2", FromCellID: "a", ToCellID: "c", Qty: d(6)},
		{GoodID: "g1", BatchID: "b1", FromCellID: "b", ToCellID: "c", Qty: d(1)},
	})
}

// Пустая ГЕ и нулевые позиции строк не дают: по ним ничего не переехало.
func TestExpand_emptyLoadUnitAndZeroLinesDropped(t *testing.T) {
	fc := &fakeContents{byID: map[string][]ContentLine{
		"empty": {},
		"zero":  {line("g1", "b1", 0)},
	}}
	got, err := Expand(context.Background(), []Move{
		{ToCellID: "c1", LoadUnitID: "empty"},
		{ToCellID: "c1", LoadUnitID: "zero"},
	}, fc)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 0 {
		t.Fatalf("ждали ни одной строки, получили %+v", got)
	}
}

// Дробные количества (uom «кг») складываются точно, без потерь float.
func TestExpand_fractionalQtyIsExact(t *testing.T) {
	q := func(s string) decimal.Decimal { return decimal.RequireFromString(s) }
	got, err := Expand(context.Background(), []Move{
		{ToCellID: "c1", GoodID: "g1", BatchID: "b1", Qty: q("0.1")},
		{ToCellID: "c1", GoodID: "g1", BatchID: "b1", Qty: q("0.2")},
	}, &fakeContents{})
	if err != nil {
		t.Fatal(err)
	}
	if !got[0].Qty.Equal(q("0.3")) {
		t.Fatalf("ждали 0.3, получили %s", got[0].Qty)
	}
}

// Одна ГЕ в двух движениях (A→B, затем B→C) — два движения, а не одно; состав читается раз.
func TestExpand_sameLoadUnitTwiceIsTwoMoves(t *testing.T) {
	fc := &fakeContents{byID: map[string][]ContentLine{"lu1": {line("g1", "b1", 2)}}}
	got, err := Expand(context.Background(), []Move{
		{FromCellID: "a", ToCellID: "b", LoadUnitID: "lu1"},
		{FromCellID: "b", ToCellID: "c", LoadUnitID: "lu1"},
	}, fc)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("ждали две строки, получили %+v", got)
	}
	if len(fc.asked) != 1 {
		t.Fatalf("состав одной ГЕ запрошен %d раз", len(fc.asked))
	}
}

func TestExpand_unknownLoadUnit(t *testing.T) {
	_, err := Expand(context.Background(), []Move{{ToCellID: "c1", LoadUnitID: "ghost"}}, &fakeContents{})
	if !errors.Is(err, ErrLoadUnitNotFound) {
		t.Fatalf("ждали ErrLoadUnitNotFound, получили %v", err)
	}
}

func TestExpand_invalidMoves(t *testing.T) {
	cases := map[string]Move{
		"ни ГЕ, ни товара":     {ToCellID: "c1"},
		"ГЕ и товар сразу":     {LoadUnitID: "lu1", GoodID: "g1", BatchID: "b1", Qty: d(1)},
		"россыпь без партии":   {GoodID: "g1", Qty: d(1)},
		"нулевое количество":   {GoodID: "g1", BatchID: "b1"},
		"отрицательное кол-во": {GoodID: "g1", BatchID: "b1", Qty: d(-1)},
	}
	for name, m := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := Expand(context.Background(), []Move{m}, &fakeContents{})
			if !errors.Is(err, ErrInvalidMove) {
				t.Fatalf("ждали ErrInvalidMove, получили %v", err)
			}
		})
	}
}

// Без ГЕ в операции состав не запрашивается вовсе.
func TestExpand_noLoadUnitsNoContentRead(t *testing.T) {
	fc := &fakeContents{}
	if _, err := Expand(context.Background(), []Move{
		{ToCellID: "c1", GoodID: "g1", BatchID: "b1", Qty: d(1)},
	}, fc); err != nil {
		t.Fatal(err)
	}
	if fc.calls != 0 {
		t.Fatalf("состав запрошен без единой ГЕ: %d", fc.calls)
	}
}

func assertLines(t *testing.T, got, want []Line) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("строк %d, ждали %d: %+v", len(got), len(want), got)
	}
	for i := range want {
		g, w := got[i], want[i]
		if g.GoodID != w.GoodID || g.BatchID != w.BatchID || g.FromCellID != w.FromCellID ||
			g.ToCellID != w.ToCellID || !g.Qty.Equal(w.Qty) {
			t.Fatalf("строка %d: получили %+v, ждали %+v", i, g, w)
		}
	}
}

// ADHOC-55: марки ЧЗ идут со своей строкой — россыпью и из состава ГЕ; одинаковые строки
// собирают марки вместе.
func TestExpand_marksFollowLines(t *testing.T) {
	fc := &fakeContents{byID: map[string][]ContentLine{
		"lu1": {{GoodID: "g1", BatchID: "b1", Qty: d(2), Marks: []string{"m1", "m2"}}},
	}}
	moves := []Move{
		{ToCellID: "c1", LoadUnitID: "lu1"},
		{ToCellID: "c1", GoodID: "g1", BatchID: "b1", Qty: d(1), Marks: []string{"m3"}},
		{ToCellID: "c2", GoodID: "g1", BatchID: "b1", Qty: d(4)},
	}
	got, err := Expand(context.Background(), moves, fc)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || strings.Join(got[0].Marks, ",") != "m1,m2,m3" || len(got[1].Marks) != 0 {
		t.Fatalf("марки строк: %+v", got)
	}
}
