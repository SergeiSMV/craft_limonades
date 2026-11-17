package service

import (
	"testing"
	"time"

	"craftwms/internal/importer"
	"craftwms/internal/model"
)

func regLine(code string, batch *time.Time, qty int, good bool) RegistryLine {
	l := RegistryLine{RegistryRow: importer.RegistryRow{GoodCode: code, GoodName: "Товар " + code, Batch: batch, Qty: qty, CellAddress: "M1-1-1-1"}}
	if good {
		l.Good = &model.RegistryGood{ID: "g-" + code, Code: code}
	}
	return l
}

func regOrder(number string, lines ...RegistryLine) RegistryOrder {
	return RegistryOrder{InvoiceNumber: "Н-" + number, OrderNumber: number, Lines: lines}
}

func exLine(id, code string, batch *time.Time, qty int, removed bool) model.PickingExistingLine {
	return model.PickingExistingLine{ID: id, GoodCode: code, BatchDate: batch, PlanQty: qty, Removed: removed}
}

func kinds(changes []model.PickingChange) []string {
	out := make([]string, 0, len(changes))
	for _, c := range changes {
		out = append(out, c.Kind)
	}
	return out
}

func sameStrings(a, b []string) bool {
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

// TestPlanRegistry - сверка файла с заказами той же даты: новый, без изменений, изменён,
// удалён, вернулся; дособор собранного, заморозка отгруженного, свёртка тройки «код + партия».
func TestPlanRegistry(t *testing.T) {
	b1 := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	picker := "u-picker"
	parsed := &RegistryParsed{Orders: []RegistryOrder{
		// Новый: тройка повторена - одна строка с суммой и первой ячейкой.
		regOrder("A", regLine("001", &b1, 2, true), regLine("001", &b1, 3, true), regLine("002", nil, 1, false)),
		// Без изменений.
		regOrder("B", regLine("001", nil, 4, true)),
		// Собранный: количество выросло, строка убрана, убранная раньше строка вернулась.
		regOrder("C", regLine("001", nil, 5, true), regLine("003", nil, 1, true)),
		// Отгруженный: изменилось количество.
		regOrder("D", regLine("001", nil, 1, true)),
		// Вернулся после удаления.
		regOrder("E", regLine("001", nil, 2, true)),
	}}
	cells := map[string]string{model.CellAddressKey("M1-1-1-1"): "c-1"}
	existing := []model.PickingExistingOrder{
		{ID: "o-B", OrderNumber: "B", Status: model.PickingStatusNew, Lines: []model.PickingExistingLine{exLine("l-B1", "001", nil, 4, false)}},
		{ID: "o-C", OrderNumber: "C", Status: model.PickingStatusPicked, PickedBy: &picker, Lines: []model.PickingExistingLine{
			exLine("l-C1", "001", nil, 3, false), exLine("l-C2", "002", nil, 1, false), exLine("l-C3", "003", nil, 1, true),
		}},
		{ID: "o-D", OrderNumber: "D", Status: model.PickingStatusShipped, Lines: []model.PickingExistingLine{exLine("l-D1", "001", nil, 2, false)}},
		{ID: "o-E", OrderNumber: "E", Status: model.PickingStatusNew, Deleted: true, Lines: []model.PickingExistingLine{exLine("l-E1", "001", nil, 2, false)}},
		// Пропал из файла.
		{ID: "o-F", OrderNumber: "F", Status: model.PickingStatusInProgress},
		// Пропал раньше и не вернулся - плана нет.
		{ID: "o-G", OrderNumber: "G", Status: model.PickingStatusNew, Deleted: true},
	}

	plans := planRegistry(parsed, cells, existing)
	if len(plans) != 6 {
		t.Fatalf("планов %d, ждали 6: %+v", len(plans), plans)
	}
	byNumber := map[string]model.PickingOrderPlan{}
	for _, p := range plans {
		n := "F"
		if p.Header != nil {
			n = p.Header.OrderNumber
		}
		byNumber[n] = p
	}

	a := byNumber["A"]
	if a.Kind != model.PickingOrderNew || len(a.Lines) != 2 || a.Lines[0].Qty != 5 || a.Lines[0].CellID == nil ||
		a.Lines[1].GoodID != nil || len(a.Changes) != 0 {
		t.Errorf("новый заказ: %+v", a)
	}
	if b := byNumber["B"]; b.Kind != model.PickingOrderUnchanged || b.Lines[0].ExistingID != "l-B1" {
		t.Errorf("без изменений: %+v", b)
	}
	c := byNumber["C"]
	if c.Kind != model.PickingOrderChanged || !c.Reopen || c.PickedBy == nil || *c.PickedBy != picker ||
		!sameStrings(kinds(c.Changes), []string{model.PickingChangeQtyChanged, model.PickingChangeLineAdded, model.PickingChangeLineRemoved}) ||
		!sameStrings(c.RemovedLineIDs, []string{"l-C2"}) || c.Lines[1].ExistingID != "l-C3" {
		t.Errorf("собранный с правкой: %+v", c)
	}
	if d := byNumber["D"]; d.Kind != model.PickingOrderChanged || !d.Frozen || d.Reopen ||
		*d.Changes[0].OldQty != 2 || *d.Changes[0].NewQty != 1 {
		t.Errorf("отгруженный: %+v", d)
	}
	if e := byNumber["E"]; e.Kind != model.PickingOrderRestored ||
		!sameStrings(kinds(e.Changes), []string{model.PickingChangeOrderRestored}) {
		t.Errorf("вернувшийся: %+v", e)
	}
	if f := byNumber["F"]; f.Kind != model.PickingOrderDeleted || f.ExistingID != "o-F" || f.Frozen ||
		!sameStrings(kinds(f.Changes), []string{model.PickingChangeOrderDeleted}) {
		t.Errorf("пропавший: %+v", f)
	}
}

// TestShortage - нехватка на файл целиком: строки с партией сверяются с остатком партии, строки
// без партии - с остатком товара за вычетом всего плана по нему.
func TestShortage(t *testing.T) {
	b1 := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	b2 := time.Date(2026, 10, 2, 0, 0, 0, 0, time.UTC)
	g := "g"
	s := newShortage([]model.PickingStock{{GoodID: g, BatchDate: b1, Qty: 5}, {GoodID: g, BatchDate: b2, Qty: 3}})
	withBatch := model.PickingPlanLine{GoodID: &g, BatchDate: &b1, Qty: 4}
	anyBatch := model.PickingPlanLine{GoodID: &g, Qty: 4}
	s.add(withBatch)
	s.add(anyBatch)
	if s.short(withBatch) || s.available(withBatch) != 5 {
		t.Errorf("партия 01.10: 4 из 5 - хватает, остаток %v", s.available(withBatch))
	}
	if s.short(anyBatch) || s.available(anyBatch) != 8 {
		t.Errorf("без партии: 8 из 8 - хватает, остаток %v", s.available(anyBatch))
	}
	s.add(model.PickingPlanLine{GoodID: &g, BatchDate: &b1, Qty: 2})
	if !s.short(withBatch) || !s.short(anyBatch) {
		t.Error("партия 01.10: 6 из 5, товар: 10 из 8 - не хватает")
	}
}
