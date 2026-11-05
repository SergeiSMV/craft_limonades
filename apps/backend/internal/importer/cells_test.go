package importer

import (
	"bytes"
	"os"
	"strings"
	"testing"

	"github.com/xuri/excelize/v2"
)

// TestParseCells_sample — образец тестов (125 ячеек M1-…, 12 стеллажей) в формате rack_labels:
// признаки размера, стрелки и штрих-кода, стеллажи с карточкой; колонки barcode_value, copies,
// print читаются без ошибок.
func TestParseCells_sample(t *testing.T) {
	res := parseFile(t, "testdata/cells_sample.xlsx")
	if len(res.Errors) != 0 {
		t.Errorf("ожидалось 0 отклонённых строк, получено %d: %+v", len(res.Errors), res.Errors)
	}
	if len(res.Cells) != 125 || len(res.Racks) != 12 || !res.HasRacksSheet {
		t.Fatalf("ячеек %d (ждали 125), стеллажей %d (ждали 12), лист racks %v",
			len(res.Cells), len(res.Racks), res.HasRacksSheet)
	}
	var floors, small, barcode, cards int
	for _, c := range res.Cells {
		if c.IsFloor {
			floors++
		}
		if c.LabelSmall {
			small++
		}
		if c.LabelBarcode {
			barcode++
		}
	}
	for _, r := range res.Racks {
		if r.SideCard {
			cards++
		}
	}
	if floors != 25 || cards != 6 {
		t.Errorf("нижних %d (ждали 25), стеллажей с карточкой %d (ждали 6)", floors, cards)
	}
	if small == 0 || barcode == 0 {
		t.Errorf("в образце есть малые балки и штрих-коды: малых %d, со штрих-кодом %d", small, barcode)
	}
	first := res.Cells[0]
	if first.Address != "M1-1-1-1" || first.RackCode != "M1-1" || !first.IsFloor || first.LabelSmall || first.LabelBarcode {
		t.Errorf("первая ячейка: %+v", first)
	}
}

// TestParseCells_rackLabelsFile — настоящий файл проекта rack_labels (522 ячейки, 66 стеллажей)
// загружается без отказов и с теми же итогами, что считал скрипт.
func TestParseCells_rackLabelsFile(t *testing.T) {
	res := parseFile(t, "testdata/rack_labels_sample.xlsx")
	if len(res.Errors) != 0 {
		t.Errorf("ожидалось 0 отклонённых строк, получено %d: %+v", len(res.Errors), res.Errors)
	}
	var small, floors, barcode, cards int
	for _, c := range res.Cells {
		if c.LabelSmall {
			small++
		}
		if c.IsFloor {
			floors++
		}
		if c.LabelBarcode {
			barcode++
		}
	}
	for _, r := range res.Racks {
		if r.SideCard {
			cards++
		}
	}
	if len(res.Cells) != 522 || len(res.Racks) != 66 || small != 30 || floors != 177 || barcode != 129 || cards != 45 {
		t.Errorf("ячеек %d/522, стеллажей %d/66, малых %d/30, нижних %d/177, со штрих-кодом %d/129, с карточкой %d/45",
			len(res.Cells), len(res.Racks), small, floors, barcode, cards)
	}
}

// TestParseCells_rejectedRows — проблемные строки уходят в отчёт с причиной, остальные принимаются.
func TestParseCells_rejectedRows(t *testing.T) {
	data := buildXLSX(t,
		[][]any{
			{"cell_id", "rack_id", "size", "arrow", "barcode"},
			{"A-1-1-1", "A-01", "LARGE", "DOWN", "TRUE"}, // регистр не важен
			{"A-1-1-1", "A-01", "large", "none", false},  // дубль адреса
			{"A-1-2-1", "A-01", "medium", "none", false}, // неизвестный size
			{"A-1-3-1", "A-01", "large", "up", false},    // стрелки вверх в WMS нет
			{"A-1-4-1", "A-01", "large", "left", false},  // неизвестная стрелка
			{"A-1-5-1", "A-01", "large", "none", "может"},
			{"A-1-6-1", "Z-99", "large", "none", false}, // стеллажа нет на листе racks
			{"", "A-01", "large", "none", false},        // без адреса
			{"A-1-7-1", "", "small", "", ""},            // без стеллажа, умолчания
		},
		[][]any{
			{"rack_id", "side_card"},
			{"A-01", "да"},
			{"A-01", "нет"}, // дубль стеллажа
		})
	res, err := ParseCells(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("ParseCells: %v", err)
	}
	if len(res.Cells) != 2 || len(res.Racks) != 1 {
		t.Fatalf("принято ячеек %d (ждали 2), стеллажей %d (ждали 1): %+v", len(res.Cells), len(res.Racks), res)
	}
	want := CellRow{Address: "A-1-1-1", RackCode: "A-01", IsFloor: true, LabelBarcode: true}
	if res.Cells[0] != want {
		t.Errorf("первая ячейка: %+v, ждали %+v", res.Cells[0], want)
	}
	if want := (CellRow{Address: "A-1-7-1", LabelSmall: true}); res.Cells[1] != want {
		t.Errorf("ячейка без стеллажа: %+v, ждали %+v", res.Cells[1], want)
	}
	if !res.Racks[0].SideCard {
		t.Error("стеллаж A-01: side_card «да» не распознан")
	}
	if len(res.Errors) != 8 {
		t.Fatalf("отклонено %d строк (ждали 8): %+v", len(res.Errors), res.Errors)
	}
	for _, sub := range []string{"повторяется", "medium", "вверх", "left", "может", "Z-99", "без адреса", "лист racks"} {
		found := false
		for _, e := range res.Errors {
			found = found || strings.Contains(e.Message, sub)
		}
		if !found {
			t.Errorf("в отчёте нет причины с %q: %+v", sub, res.Errors)
		}
	}
}

// TestParseCells_withoutRacksSheet — без листа racks стеллаж берётся из колонки как есть.
func TestParseCells_withoutRacksSheet(t *testing.T) {
	data := buildXLSX(t, [][]any{{"cell_id", "rack_id", "size"}, {"A-1-1-1", "A-01", "large"}}, nil)
	res, err := ParseCells(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("ParseCells: %v", err)
	}
	if res.HasRacksSheet || len(res.Cells) != 1 || res.Cells[0].RackCode != "A-01" || len(res.Errors) != 0 {
		t.Errorf("результат: %+v", res)
	}
}

// TestParseCells_badFile — не xlsx, нет листа cells, нет обязательной колонки → ошибка, а не
// тихая загрузка пустоты.
func TestParseCells_badFile(t *testing.T) {
	if _, err := ParseCells(strings.NewReader("не xlsx")); err == nil {
		t.Error("невалидный файл: ожидалась ошибка")
	}
	old := buildXLSXSheet(t, "Лист1", [][]any{{"cell", "floor"}, {"M1-1-1-1", "true"}})
	if _, err := ParseCells(bytes.NewReader(old)); err == nil || !strings.Contains(err.Error(), "cells") {
		t.Errorf("старый формат cell/floor: ожидалась ошибка про лист cells, получено %v", err)
	}
	noSize := buildXLSX(t, [][]any{{"cell_id", "rack_id"}, {"A-1-1-1", "A-01"}}, nil)
	if _, err := ParseCells(bytes.NewReader(noSize)); err == nil || !strings.Contains(err.Error(), "size") {
		t.Errorf("нет колонки size: ожидалась ошибка, получено %v", err)
	}
}

// TestParseBool — словарь булевых значений rack_labels.
func TestParseBool(t *testing.T) {
	cases := map[string]struct {
		val, ok bool
	}{
		"true": {true, true}, "TRUE": {true, true}, "1": {true, true}, "да": {true, true},
		"yes": {true, true}, "+": {true, true}, "истина": {true, true},
		"false": {false, true}, "FALSE": {false, true}, "0": {false, true}, "нет": {false, true},
		"-": {false, true}, "ложь": {false, true},
		"":      {false, true},
		"maybe": {false, false},
	}
	for in, want := range cases {
		got, ok := parseBool(in)
		if got != want.val || ok != want.ok {
			t.Errorf("parseBool(%q) = (%v,%v), ожидалось (%v,%v)", in, got, ok, want.val, want.ok)
		}
	}
}

func parseFile(t *testing.T, path string) *CellsParseResult {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("открыть %s: %v", path, err)
	}
	defer func() { _ = f.Close() }()
	res, err := ParseCells(f)
	if err != nil {
		t.Fatalf("ParseCells(%s): %v", path, err)
	}
	return res
}

// buildXLSX собирает книгу с листами cells и (если racks не nil) racks.
func buildXLSX(t *testing.T, cells, racks [][]any) []byte {
	t.Helper()
	f := excelize.NewFile()
	defer func() { _ = f.Close() }()
	if err := f.SetSheetName("Sheet1", SheetCells); err != nil {
		t.Fatal(err)
	}
	fill(t, f, SheetCells, cells)
	if racks != nil {
		if _, err := f.NewSheet(SheetRacks); err != nil {
			t.Fatal(err)
		}
		fill(t, f, SheetRacks, racks)
	}
	return save(t, f)
}

// buildXLSXSheet — книга с одним листом произвольного имени.
func buildXLSXSheet(t *testing.T, name string, rows [][]any) []byte {
	t.Helper()
	f := excelize.NewFile()
	defer func() { _ = f.Close() }()
	if err := f.SetSheetName("Sheet1", name); err != nil {
		t.Fatal(err)
	}
	fill(t, f, name, rows)
	return save(t, f)
}

func fill(t *testing.T, f *excelize.File, sheet string, rows [][]any) {
	t.Helper()
	for i, row := range rows {
		cell, _ := excelize.CoordinatesToCellName(1, i+1)
		if err := f.SetSheetRow(sheet, cell, &row); err != nil {
			t.Fatal(err)
		}
	}
}

func save(t *testing.T, f *excelize.File) []byte {
	t.Helper()
	buf, err := f.WriteToBuffer()
	if err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}
