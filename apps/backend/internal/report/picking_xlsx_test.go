package report

import (
	"reflect"
	"testing"
	"time"

	"github.com/shopspring/decimal"

	"craftwms/internal/model"
)

// CZ-07: целый короб ЧЗ в выгрузке «Сборка-отгрузка» - строкой с кодом агрегации и его марками
// ниже, россыпь - марками. Лист «Марки для УПД» - только собранный и отгруженный заказ и только
// перенесённое в короба отгрузки.
func TestBuildPickingXLSX_czMarks(t *testing.T) {
	const (
		box  = "00046000000000000017"
		m1   = "0104600000000017215AAA01"
		m2   = "0104600000000017215AAA02"
		m3   = "0104600000000017215AAA03"
		open = "0104600000000017215AAA04"
	)
	day := func(d int) time.Time { return time.Date(2026, 10, d, 0, 0, 0, 0, time.UTC) }
	line := model.PickingPortalLine{
		LineNo: 1, GoodCode: "00000016149", GoodName: "Вода", Known: true, Uom: "шт", CZMarked: true,
		PlanQty: 3,
		Facts: []model.PickingPortalFact{
			{BatchDate: day(1), CellAddress: "A-1", BoxSeq: 1, Qty: decimal.NewFromInt(3),
				State: model.PickingPickMoved, Marks: []string{m3, m1, m2}},
		},
	}
	shipped := model.PickingPortalDetail{
		Order: model.PickingPortalOrder{Number: 7, InvoiceNumber: "20961", OrderNumber: "15512",
			Client: "Магазин", Status: model.PickingStatusShipped, RegistryDate: day(9)},
		Lines:   []model.PickingPortalLine{line},
		CZBoxes: []model.PickingCZBox{{Code: box, Kind: model.CZAggregateBox, Marks: []string{m1, m2}}},
	}
	inWork := model.PickingPortalDetail{
		Order: model.PickingPortalOrder{Number: 8, InvoiceNumber: "20962", OrderNumber: "15513",
			Status: model.PickingStatusInProgress, RegistryDate: day(9)},
		Lines: []model.PickingPortalLine{{LineNo: 1, GoodCode: "00000016149", GoodName: "Вода", PlanQty: 1,
			Facts: []model.PickingPortalFact{{BatchDate: day(1), CellAddress: "A-1", BoxSeq: 1,
				Qty: decimal.NewFromInt(1), State: "picking", Marks: []string{open}}}}},
	}

	raw, err := BuildPickingXLSX(day(9), []model.PickingPortalDetail{shipped, inWork})
	if err != nil {
		t.Fatal(err)
	}
	f := openSheet(t, raw)

	// «Сборка»: после первой строки факта (марка россыпью m3) - код короба с пометкой и его марки.
	rows, err := f.GetRows(pickingMainSheet)
	if err != nil {
		t.Fatal(err)
	}
	var codes, notes []string
	for _, r := range rows {
		if len(r) == len(pickingLineHeaders) && r[0] != "№" {
			codes = append(codes, r[13])
			notes = append(notes, r[12])
		}
	}
	if want := []string{m3, box, m1, m2, open}; !reflect.DeepEqual(codes, want) {
		t.Fatalf("коды ЧЗ на листе «Сборка»: %q, ожидалось %q", codes, want)
	}
	if notes[1] != "короб ЧЗ целиком, марок: 2" || notes[2] != "" {
		t.Fatalf("пометки кодов: %q", notes)
	}

	// «Марки для УПД»: заказ в работе не попал; короб - строкой с кодом, марки - ниже.
	rows, err = f.GetRows(pickingMarksSheet)
	if err != nil {
		t.Fatal(err)
	}
	var got [][]string
	for _, r := range rows[1:] {
		got = append(got, []string{r[0], r[7], r[8], r[9]})
	}
	want := [][]string{
		{"СБ-000007", "01.10.2026", m3, "марка"},
		{"СБ-000007", "01.10.2026", box, "короб ЧЗ"},
		{"СБ-000007", "01.10.2026", m1, "в коробе ЧЗ"},
		{"СБ-000007", "01.10.2026", m2, "в коробе ЧЗ"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("лист «Марки для УПД»:\n%q\nожидалось\n%q", got, want)
	}
	if rows[1][3] != "Магазин" || rows[1][4] != "отгружен" || rows[1][5] != "00000016149" {
		t.Fatalf("шапка строки: %q", rows[1])
	}
}
