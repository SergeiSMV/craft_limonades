package report

import (
	"testing"
	"time"

	"craftwms/internal/model"
)

func movementSnap() model.ReportSnapshot {
	code := "16121"
	return model.ReportSnapshot{
		WarehouseCode: "SHB",
		WarehouseName: "Шабулина",
		Operation:     model.MovementOperationPutaway,
		TaskNumber:    57,
		Number:        3,
		SourceNumber:  12,
		Supplier:      "ООО «Голсера»",
		DocNumber:     "ТН-1042/2",
		DocDate:       "2026-10-01",
		Executor:      "Иванов Иван",
		CreatedAt:     time.Date(2026, 10, 5, 22, 30, 0, 0, time.UTC),
		Rows: []model.ReportSnapshotRow{
			{FromCellAddress: "С-Н-П", CellAddress: "M1-1-10-1", GoodCode: &code, GoodName: "Кальмар", ProductionDate: "2026-09-01", Qty: "24"},
			{FromCellAddress: "С-Н-П", CellAddress: "M1-1-10-2", GoodName: "Креветка", ProductionDate: "2026-09-02", Qty: "1.5"},
		},
	}
}

func movementValue(t *testing.T, raw []byte, cell string) string {
	t.Helper()
	v, err := openSheet(t, raw).GetCellValue(movementSheet, cell)
	if err != nil {
		t.Fatalf("ячейка %s: %v", cell, err)
	}
	return v
}

// Шапка: операция, склад, основание (задание, поставщик, его накладная), исполнитель, дата по
// Москве; таблица - откуда · куда · товар по партиям.
func TestBuildMovementXLSX(t *testing.T) {
	raw, err := BuildMovementXLSX(movementSnap())
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"A1": "Движение", "B1": "ДД-000003",
		"A2": "Операция", "B2": "Размещение РЗ-000012",
		"A3": "Склад", "B3": "Шабулина",
		"A4": "Задание", "B4": "ЗД-000057",
		"A5": "Поставщик", "B5": "ООО «Голсера»",
		"A6": "Документ поставщика", "B6": "№ ТН-1042/2 от 01.10.2026",
		"A7": "Исполнитель", "B7": "Иванов Иван",
		"A8": "Дата", "B8": "06.10.2026 01:30",
		"A10": "Откуда", "B10": "Куда", "C10": "Код", "D10": "Наименование", "E10": "Дата выпуска", "F10": "Количество",
		"A11": "С-Н-П", "B11": "M1-1-10-1", "C11": "16121", "D11": "Кальмар", "E11": "01.09.2026", "F11": "24",
		"B12": "M1-1-10-2", "C12": "", "D12": "Креветка", "F12": "1.5",
	}
	for cell, v := range want {
		if got := movementValue(t, raw, cell); got != v {
			t.Errorf("%s: получили %q, ждали %q", cell, got, v)
		}
	}
}

// Без задания и без поставщика (перемещение P6, приёмка без поставщика) строк основания нет.
func TestBuildMovementXLSX_noBasis(t *testing.T) {
	snap := movementSnap()
	snap.TaskNumber, snap.Supplier, snap.DocNumber, snap.DocDate = 0, "", "", ""
	raw, err := BuildMovementXLSX(snap)
	if err != nil {
		t.Fatal(err)
	}
	if got := movementValue(t, raw, "A4"); got != "Исполнитель" {
		t.Errorf("A4: %q, ожидалось «Исполнитель»", got)
	}
}

// Задание по решению «разместить» (ADHOC-55): основание - проблема склада под её номером,
// строк поставщика нет.
func TestBuildMovementXLSX_problemBasis(t *testing.T) {
	snap := movementSnap()
	snap.Supplier, snap.DocNumber, snap.DocDate = "", "", ""
	snap.ProblemNumber = 1
	raw, err := BuildMovementXLSX(snap)
	if err != nil {
		t.Fatal(err)
	}
	for cell, v := range map[string]string{
		"A4": "Задание", "B4": "ЗД-000057",
		"A5": "Проблема склада", "B5": "ПБ-000001",
		"A6": "Исполнитель",
	} {
		if got := movementValue(t, raw, cell); got != v {
			t.Errorf("%s: получили %q, ждали %q", cell, got, v)
		}
	}
}

// Марка (ADHOC-55) - последней колонкой; строка без марки оставляет её пустой.
func TestBuildMovementXLSX_mark(t *testing.T) {
	snap := movementSnap()
	snap.Rows[0].Qty, snap.Rows[0].Mark = "1", "0104600000000017215L1"
	raw, err := BuildMovementXLSX(snap)
	if err != nil {
		t.Fatal(err)
	}
	for cell, v := range map[string]string{
		"G10": "Марка", "G11": "0104600000000017215L1", "F11": "1", "G12": "",
	} {
		if got := movementValue(t, raw, cell); got != v {
			t.Errorf("%s: получили %q, ждали %q", cell, got, v)
		}
	}
}

// Развилка «форма → шаблон» и имя файла знают «Движение».
func TestBuildDocumentXLSX_movement(t *testing.T) {
	doc := model.ReportDocument{
		Kind:      model.ReportKindMovement,
		Snapshot:  movementSnap(),
		CreatedAt: time.Date(2026, 10, 5, 10, 0, 0, 0, time.UTC),
	}
	if _, err := BuildDocumentXLSX(doc); err != nil {
		t.Fatalf("сборка по форме: %v", err)
	}
	if got := DocumentFilename(doc); got != "dvizhenie-SHB-20261005.xlsx" {
		t.Fatalf("имя файла: %q", got)
	}
}

// Операция в шапке - по-человечески для всех трёх движений; незнакомая - как есть.
func TestMovementOperationTitle(t *testing.T) {
	for op, want := range map[string]string{
		model.MovementOperationPutaway:   "Размещение",
		model.MovementOperationMove:      "Перемещение",
		model.MovementOperationReplenish: "Пополнение",
		"teleport":                       "teleport",
	} {
		if got := movementOperationTitle(op); got != want {
			t.Errorf("%q: %q, ожидалось %q", op, got, want)
		}
	}
}
