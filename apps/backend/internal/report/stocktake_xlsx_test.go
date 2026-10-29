package report

import (
	"testing"
	"time"

	"craftwms/internal/model"
)

// P10-05: «Инвентаризация» — шапка с номером документа и пересчёта (ADHOC-55), все позиции с ожидалось/факт/расхождение на первом
// листе, на втором — только расхождения и пометки; «не считалась» — без чисел.
func TestBuildStocktakeXLSX(t *testing.T) {
	code := "16121"
	raw, err := BuildStocktakeXLSX(model.ReportSnapshot{
		WarehouseName: "Шабулина", StocktakeNumber: 12, Number: 4, ScopeKind: model.StocktakeScopeAll,
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
		"A1": "Инвентаризация", "B1": "ДИ-000004", "A2": "Пересчёт", "B2": "ИН-000012",
		"B4": "весь склад", "B5": "Петров Пётр", "B6": "26.10.2026 12:00",
		"A8": "Ячейка", "H8": "Расхождение", "J8": "Марка",
		"A9": "A1", "B9": "16121", "D9": "01.09.2026", "E9": "Основной", "F9": "10", "G9": "10", "H9": "0",
		"A10": "A2", "H10": "-12", "I10": "не найдено — проблема склада",
		"A11": "A3", "F11": "", "I11": "не считалась",
	} {
		if got := get(stocktakeSheet, cell); got != want {
			t.Errorf("%s: %q, ожидалось %q", cell, got, want)
		}
	}
	if a9, a10 := get(stocktakeDiffSheet, "A9"), get(stocktakeDiffSheet, "A10"); a9 != "A2" || a10 != "A3" {
		t.Errorf("лист расхождений: %q, %q — ожидались A2 и A3", a9, a10)
	}
	if got := get(stocktakeDiffSheet, "A11"); got != "" {
		t.Errorf("на листе расхождений лишняя строка %q", got)
	}
}
