package report

import (
	"bytes"
	"testing"
	"time"

	"github.com/xuri/excelize/v2"

	"craftwms/internal/model"
)

func receiptSnap() model.ReportSnapshot {
	code := "16121"
	return model.ReportSnapshot{
		WarehouseCode: "SHB",
		WarehouseName: "Шабулина",
		Supplier:      "ООО «Голсера»",
		Executor:      "Иванов Иван",
		// 22:30 UTC — уже следующий день по Москве.
		CreatedAt: time.Date(2026, 10, 5, 22, 30, 0, 0, time.UTC),
		Rows: []model.ReportSnapshotRow{
			{CellAddress: "С-Н-П", GoodCode: &code, GoodName: "Кальмар", ProductionDate: "2026-09-01", Qty: "36"},
			{CellAddress: "С-Н-П", GoodName: "Креветка", ProductionDate: "2026-09-02", Qty: "1.5"},
		},
	}
}

func openSheet(t *testing.T, raw []byte) *excelize.File {
	t.Helper()
	f, err := excelize.OpenReader(bytes.NewReader(raw))
	if err != nil {
		t.Fatalf("открыть xlsx: %v", err)
	}
	t.Cleanup(func() { _ = f.Close() })
	return f
}

func cellValue(t *testing.T, f *excelize.File, cell string) string {
	t.Helper()
	v, err := f.GetCellValue(receiptSheet, cell)
	if err != nil {
		t.Fatalf("ячейка %s: %v", cell, err)
	}
	return v
}

// Шапка: склад, поставщик, исполнитель и дата по Москве; таблица товаров по партиям.
func TestBuildReceiptXLSX(t *testing.T) {
	raw, err := BuildReceiptXLSX(receiptSnap())
	if err != nil {
		t.Fatal(err)
	}
	f := openSheet(t, raw)

	want := map[string]string{
		"A1": "Поступление",
		"A2": "Склад", "B2": "Шабулина",
		"A3": "Поставщик", "B3": "ООО «Голсера»",
		"A4": "Исполнитель", "B4": "Иванов Иван",
		"A5": "Дата", "B5": "06.10.2026 01:30", // сервер в UTC, документ — по Москве
		"A7": "Ячейка", "B7": "Код", "C7": "Наименование", "D7": "Дата выпуска", "E7": "Количество",
		"A8": "С-Н-П", "B8": "16121", "C8": "Кальмар", "D8": "01.09.2026", "E8": "36",
		"B9": "", "C9": "Креветка", "E9": "1.5",
	}
	for cell, v := range want {
		if got := cellValue(t, f, cell); got != v {
			t.Errorf("%s: получили %q, ждали %q", cell, got, v)
		}
	}
	// Количество — числом, а не текстом: оператор сверяет суммы в Excel.
	if typ, _ := f.GetCellType(receiptSheet, "E9"); typ == excelize.CellTypeSharedString || typ == excelize.CellTypeInlineString {
		t.Error("количество записано текстом")
	}
}

func TestBuildReceiptXLSX_noSupplier(t *testing.T) {
	snap := receiptSnap()
	snap.Supplier = ""
	raw, err := BuildReceiptXLSX(snap)
	if err != nil {
		t.Fatal(err)
	}
	if got := cellValue(t, openSheet(t, raw), "B3"); got != "без поставщика" {
		t.Fatalf("поставщик: %q", got)
	}
}

// Развилка «форма → шаблон» и имя файла знают «Поступление».
func TestBuildDocumentXLSX_receipt(t *testing.T) {
	doc := model.ReportDocument{
		Kind:      model.ReportKindReceipt,
		Snapshot:  receiptSnap(),
		CreatedAt: time.Date(2026, 10, 5, 10, 0, 0, 0, time.UTC),
	}
	if _, err := BuildDocumentXLSX(doc); err != nil {
		t.Fatalf("сборка по форме: %v", err)
	}
	if got := DocumentFilename(doc); got != "postuplenie-SHB-20261005.xlsx" {
		t.Fatalf("имя файла: %q", got)
	}
}
