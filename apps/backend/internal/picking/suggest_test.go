package picking

import (
	"testing"
	"time"

	"github.com/shopspring/decimal"
)

var (
	d1 = time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC)
	d2 = time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	d3 = time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
)

func qty(n int64) decimal.Decimal { return decimal.NewFromInt(n) }

func ptr[T any](v T) *T { return &v }

// src — источник товара g1 склада «Основной»; lu пуст — россыпь.
func src(cell string, lu string, batch time.Time, n int64) Source {
	return Source{
		CellID: cell, CellAddress: cell, LoadUnitID: lu, InternalWarehouseID: "main",
		GoodID: "g1", BatchID: batch.Format(time.DateOnly), BatchDate: batch, Available: qty(n),
	}
}

// takes — подбор строкой «ячейка/короб:партия:кол-во» для сравнения в таблице.
func takes(sg Suggestion) []string {
	var out []string
	for _, t := range sg.Takes {
		place := t.Source.CellID
		if t.Source.LoadUnitID != "" {
			place += "/" + t.Source.LoadUnitID
		}
		out = append(out, place+":"+t.Source.BatchDate.Format("01")+":"+t.Qty.String())
	}
	return out
}

func equal(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestSuggestOrder_line(t *testing.T) {
	cases := []struct {
		name      string
		line      Line
		sources   []Source
		want      []string
		short     int64
		batchSubs bool
		cellSubs  bool
	}{
		{
			name:    "партия и ячейка реестра есть - берутся они",
			line:    Line{GoodID: "g1", BatchDate: &d2, CellID: ptr("B-1"), RegistryCell: "В-1", PlanQty: qty(5)},
			sources: []Source{src("A-1", "", d1, 50), src("B-1", "", d2, 10), src("C-1", "", d2, 30)},
			want:    []string{"B-1:10:5"},
		},
		{
			name:      "партии реестра нет в остатке - FEFO",
			line:      Line{GoodID: "g1", BatchDate: &d3, PlanQty: qty(5)},
			sources:   []Source{src("A-1", "", d2, 50), src("B-1", "", d1, 3), src("C-1", "", d1, 4)},
			want:      []string{"C-1:09:4", "B-1:09:1"},
			batchSubs: true,
		},
		{
			name:      "партии реестра не хватает - остаток FEFO",
			line:      Line{GoodID: "g1", BatchDate: &d2, PlanQty: qty(8)},
			sources:   []Source{src("A-1", "", d2, 5), src("B-1", "", d3, 10), src("C-1", "", d1, 10)},
			want:      []string{"A-1:10:5", "C-1:09:3"},
			batchSubs: true,
		},
		{
			name:     "в ячейке реестра нет товара - ячейка WMS",
			line:     Line{GoodID: "g1", BatchDate: &d2, CellID: ptr("B-1"), RegistryCell: "В-1", PlanQty: qty(5)},
			sources:  []Source{src("C-1", "", d2, 30)},
			want:     []string{"C-1:10:5"},
			cellSubs: true,
		},
		{
			name:     "ячейки реестра нет в WMS - ячейка WMS, реестровая серым",
			line:     Line{GoodID: "g1", RegistryCell: "А-9-9", PlanQty: qty(2)},
			sources:  []Source{src("C-1", "", d2, 30)},
			want:     []string{"C-1:10:2"},
			cellSubs: true,
		},
		{
			name:    "без партии и ячейки - FEFO, россыпь раньше короба",
			line:    Line{GoodID: "g1", PlanQty: qty(6)},
			sources: []Source{src("A-1", "lu1", d1, 20), src("B-1", "", d1, 4), src("C-1", "", d2, 50)},
			want:    []string{"B-1:09:4", "A-1/lu1:09:2"},
		},
		{
			name:    "больше доступного - раньше",
			line:    Line{GoodID: "g1", PlanQty: qty(6)},
			sources: []Source{src("A-1", "", d1, 4), src("B-1", "", d1, 9)},
			want:    []string{"B-1:09:6"},
		},
		{
			name:    "уже взято - подбирается разница",
			line:    Line{GoodID: "g1", PlanQty: qty(6), Taken: qty(4)},
			sources: []Source{src("A-1", "", d1, 10)},
			want:    []string{"A-1:09:2"},
		},
		{
			name:    "собрано всё - подбора нет",
			line:    Line{GoodID: "g1", PlanQty: qty(6), Taken: qty(6)},
			sources: []Source{src("A-1", "", d1, 10)},
		},
		{
			name:    "остатка не хватает - нехватка",
			line:    Line{GoodID: "g1", PlanQty: qty(10)},
			sources: []Source{src("A-1", "", d1, 3)},
			want:    []string{"A-1:09:3"},
			short:   7,
		},
		{
			name:  "остатка нет совсем",
			line:  Line{GoodID: "g1", PlanQty: qty(10)},
			short: 10,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			sg := SuggestOrder([]Line{tc.line}, tc.sources)[0]
			if got := takes(sg); !equal(got, tc.want) {
				t.Fatalf("подбор: got %v, want %v", got, tc.want)
			}
			if !sg.Short.Equal(qty(tc.short)) {
				t.Errorf("нехватка: got %s, want %d", sg.Short, tc.short)
			}
			if sg.BatchSubstituted != tc.batchSubs || sg.CellSubstituted != tc.cellSubs {
				t.Errorf("замены: партия %v ячейка %v, want %v %v",
					sg.BatchSubstituted, sg.CellSubstituted, tc.batchSubs, tc.cellSubs)
			}
		})
	}
}

// Две строки одного товара делят доступное: строка с партией реестра берёт свою партию первой,
// даже если в файле она ниже строки без партии.
func TestSuggestOrder_sharedPool(t *testing.T) {
	lines := []Line{
		{ID: "free", GoodID: "g1", PlanQty: qty(6)},
		{ID: "batch", GoodID: "g1", BatchDate: &d1, PlanQty: qty(4)},
	}
	sources := []Source{src("A-1", "", d1, 5), src("B-1", "", d2, 10)}

	got := SuggestOrder(lines, sources)
	if got[0].LineID != "free" || got[1].LineID != "batch" {
		t.Fatalf("порядок строк: %s, %s", got[0].LineID, got[1].LineID)
	}
	if w := []string{"A-1:09:4"}; !equal(takes(got[1]), w) {
		t.Errorf("строка с партией: got %v, want %v", takes(got[1]), w)
	}
	if w := []string{"A-1:09:1", "B-1:10:5"}; !equal(takes(got[0]), w) {
		t.Errorf("строка без партии: got %v, want %v", takes(got[0]), w)
	}
	if !sources[0].Available.Equal(qty(5)) {
		t.Errorf("входные источники изменены: %s", sources[0].Available)
	}
}

// Источник чужого товара строке не достаётся.
func TestSuggestOrder_otherGood(t *testing.T) {
	other := src("A-1", "", d1, 10)
	other.GoodID = "g2"
	sg := SuggestOrder([]Line{{GoodID: "g1", PlanQty: qty(1)}}, []Source{other})[0]
	if len(sg.Takes) != 0 || !sg.Short.Equal(qty(1)) {
		t.Fatalf("got %v, нехватка %s", takes(sg), sg.Short)
	}
}
