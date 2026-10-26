package report

import (
	"testing"
	"time"

	"craftwms/internal/model"
)

// P10-05: «Инвентаризация» — шапка пересчёта, все позиции с ожидалось/факт/расхождение на первом
// листе, на втором — только расхождения и пометки; «не считалась» — без чисел.
func TestBuildStocktakeXLSX(t *testing.T) {
	code := "16121"
	raw, err := BuildStocktakeXLSX(model.ReportSnapshot{
		WarehouseName: "Шабулина", StocktakeNumber: 12, ScopeKind: model.StocktakeScopeAll,
		Executor: "Петров Пётр", CreatedAt: time.Date(2026, 10, 26, 9, 0, 0, 0, time.UTC),
		Rows: []model.ReportSnapshotRow{
			{CellAddress: "A1", GoodCode: &code, GoodName: "Кальмар", ProductionDate: "2026-09-01",
				InternalWarehouse: "Основной", Expected: "10", Fact: "10", Diff: "0"},
			{CellAddress: "A2", GoodName: "Креветка", ProductionDate: "2026-09-02",
				InternalWarehouse: "Основной", Expected: "12", Fact: "0", Diff: "-12", Note: "не найдено — проблема склада"},
			{CellAddress: "A3", Note: "не считалась"},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	f := openSheet(t, raw)
	get := func(sheet, cell string) string {
		v, err := f.GetCellValue(sheet, cell)
		if err != nil {
			t.Fatalf("%s!%s: %v", sheet, cell, err)
		}
		return v
	}
	for cell, want := range map[string]string{
		"B1": "Пересчёт № 12", "B3": "весь склад", "B4": "Петров Пётр", "B5": "26.10.2026 12:00",
		"A7": "Ячейка", "H7": "Расхождение",
		"A8": "A1", "B8": "16121", "D8": "01.09.2026", "E8": "Основной", "F8": "10", "G8": "10", "H8": "0",
		"A9": "A2", "H9": "-12", "I9": "не найдено — проблема склада",
		"A10": "A3", "F10": "", "I10": "не считалась",
	} {
		if got := get(stocktakeSheet, cell); got != want {
			t.Errorf("%s: %q, ожидалось %q", cell, got, want)
		}
	}
	if a8, a9 := get(stocktakeDiffSheet, "A8"), get(stocktakeDiffSheet, "A9"); a8 != "A2" || a9 != "A3" {
		t.Errorf("лист расхождений: %q, %q — ожидались A2 и A3", a8, a9)
	}
	if got := get(stocktakeDiffSheet, "A10"); got != "" {
		t.Errorf("на листе расхождений лишняя строка %q", got)
	}
}
