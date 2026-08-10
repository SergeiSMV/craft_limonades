package service

import (
	"sort"
	"testing"
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
