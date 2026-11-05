package service

import (
	"fmt"
	"sort"
	"testing"

	"craftwms/internal/model"
)

// naturalLess — цифровые сегменты по значению: M1-1-2-1 раньше M1-1-10-1 (а не лексикографически).
func TestNaturalLess_ordersNumericSegments(t *testing.T) {
	in := []string{"M1-1-10-1", "M1-1-2-1", "M1-1-1-1", "M1-1-1-2", "M2-1-1-1"}
	want := []string{"M1-1-1-1", "M1-1-1-2", "M1-1-2-1", "M1-1-10-1", "M2-1-1-1"}

	sort.Slice(in, func(i, j int) bool { return naturalLess(in[i], in[j]) })

	for i := range want {
		if in[i] != want[i] {
			t.Fatalf("натуральная сортировка: позиция %d — ожидалось %q, получено %q (итог %v)", i, want[i], in[i], in)
		}
	}
}


// Порядок наклейки: стеллаж натурально, без стеллажа — в конце; в стеллаже позиция слева
// направо, в позиции ярусы сверху вниз (как первая страница labels_large у rack_labels).
func TestCellBefore_stickingOrder(t *testing.T) {
	in := []model.CellSetup{
		{Address: "Z-1-1"},
		{Address: "B-1-1-2", RackCode: ptr("B-01")},
		{Address: "B-1-1-1", RackCode: ptr("B-01")},
		{Address: "C-1-1-1", RackCode: ptr("B-10")},
		{Address: "B-1-3-1", RackCode: ptr("B-01")},
		{Address: "B-2-1-1", RackCode: ptr("B-02")},
	}
	want := []string{"B-1-3-1", "B-1-1-1", "B-1-1-2", "B-2-1-1", "C-1-1-1", "Z-1-1"}
	sort.Slice(in, func(i, j int) bool { return cellBefore(in[i], in[j]) })
	for i := range want {
		if in[i].Address != want[i] {
			t.Fatalf("позиция %d: %q, ждали %q (%v)", i, in[i].Address, want[i], in)
		}
	}
}

// Карточка — только стеллажи выбранных ячеек с галочкой, строки всего стеллажа: позиции
// убывают, ярусы сверху вниз. Набор для кегля — все карточки склада.
func TestSideCards_rowsOfWholeRack(t *testing.T) {
	cells := []model.CellSetup{
		{ID: "1", Address: "B-1-1-1", RackID: ptr("r1")},
		{ID: "2", Address: "B-1-2-1", RackID: ptr("r1")},
		{ID: "3", Address: "B-1-1-2", RackID: ptr("r1")},
		{ID: "4", Address: "C-1-1-1", RackID: ptr("r2")},
		{ID: "5", Address: "D-1-1-1", RackID: ptr("r3")},
		{ID: "6", Address: "E-1-1-1"},
	}
	racks := []model.Rack{{ID: "r1", Code: "B-01", SideCard: true}, {ID: "r2", Code: "C-01"}, {ID: "r3", Code: "D-01", SideCard: true}}
	cards, set := sideCards(cells, racks, []model.CellSetup{cells[0], cells[3], cells[5]})
	if len(cards) != 1 || cards[0].Rack != "B-01" || len(set) != 4 {
		t.Fatalf("карточки %+v, набор %v", cards, set)
	}
	got := ""
	for _, r := range cards[0].Rows {
		got += fmt.Sprintf("%s/%d ", r.Address, r.Position)
	}
	if got != "B-1-1-2/2 B-1-2-1/1 B-1-1-1/1 " {
		t.Errorf("строки: %s", got)
	}
}
