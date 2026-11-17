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
		DocNumber:     "ТН-1042/2",
		DocDate:       "2026-10-01",
		// 22:30 UTC - уже следующий день по Москве.
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
		"A4": "Документ поставщика", "B4": "№ ТН-1042/2 от 01.10.2026",
		"A5": "Исполнитель", "B5": "Иванов Иван",
		"A6": "Дата", "B6": "06.10.2026 01:30", // сервер в UTC, документ - по Москве
		"A8": "Ячейка", "B8": "Код", "C8": "Наименование", "D8": "Дата выпуска", "E8": "Количество",
		"A9": "С-Н-П", "B9": "16121", "C9": "Кальмар", "D9": "01.09.2026", "E9": "36",
		"B10": "", "C10": "Креветка", "E10": "1.5",
	}
	for cell, v := range want {
		if got := cellValue(t, f, cell); got != v {
			t.Errorf("%s: получили %q, ждали %q", cell, got, v)
		}
	}
	// Количество - числом, а не текстом: оператор сверяет суммы в Excel.
	if typ, _ := f.GetCellType(receiptSheet, "E10"); typ == excelize.CellTypeSharedString || typ == excelize.CellTypeInlineString {
		t.Error("количество записано текстом")
	}
}

// ADHOC-55: номер документа - рядом с названием формы, номер приёмки - строкой под ним.
func TestBuildReceiptXLSX_numbers(t *testing.T) {
	snap := receiptSnap()
	snap.Number, snap.SourceNumber = 5, 21
	raw, err := BuildReceiptXLSX(snap)
	if err != nil {
		t.Fatal(err)
	}
	f := openSheet(t, raw)
	for cell, v := range map[string]string{
		"A1": "Поступление", "B1": "ДП-000005", "A2": "Приёмка", "B2": "ПР-000021", "A3": "Склад",
	} {
		if got := cellValue(t, f, cell); got != v {
			t.Errorf("%s: получили %q, ждали %q", cell, got, v)
		}
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

// Снимок до ADHOC-23 накладной не несёт - строки «Документ поставщика» нет, шапка прежняя.
func TestBuildReceiptXLSX_snapshotWithoutDoc(t *testing.T) {
	snap := receiptSnap()
	snap.DocNumber, snap.DocDate = "", ""
	raw, err := BuildReceiptXLSX(snap)
	if err != nil {
		t.Fatal(err)
	}
	f := openSheet(t, raw)
	if got := cellValue(t, f, "A4"); got != "Исполнитель" {
		t.Errorf("A4: %q, ожидалось «Исполнитель»", got)
	}
}
