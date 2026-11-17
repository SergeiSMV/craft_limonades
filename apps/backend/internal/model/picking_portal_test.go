package model

import (
	"testing"
	"time"

	"github.com/shopspring/decimal"
)

// TestClassifyPickingChanges - причина правки реестра (P9-08): до сборки - заказ, во время
// сборки - сборка, после отгрузки - к факту или расходится, по строке (код + партия) и по заказу.
func TestClassifyPickingChanges(t *testing.T) {
	b1 := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	ptr := func(v int) *int { return &v }
	d := PickingPortalDetail{
		Lines: []PickingPortalLine{
			{GoodCode: "001", BatchDate: &b1, Facts: []PickingPortalFact{
				{Qty: decimal.NewFromInt(4), State: PickingPickMoved},
				{Qty: decimal.NewFromInt(2), State: PickingPickMoved},
			}},
			// Та же позиция без партии - другая строка; пик «в сборке» не отгружен.
			{GoodCode: "001", Facts: []PickingPortalFact{{Qty: decimal.NewFromInt(3), State: "picking"}}},
		},
		Changes: []PickingPortalChange{
			{Kind: PickingChangeQtyChanged, GoodCode: "001", BatchDate: &b1, OldQty: ptr(10), NewQty: ptr(8), OrderStatus: PickingStatusNew},
			{Kind: PickingChangeQtyChanged, GoodCode: "001", BatchDate: &b1, OldQty: ptr(8), NewQty: ptr(10), OrderStatus: PickingStatusPicked},
			{Kind: PickingChangeQtyChanged, GoodCode: "001", BatchDate: &b1, OldQty: ptr(10), NewQty: ptr(6), OrderStatus: PickingStatusShipped},
			{Kind: PickingChangeQtyChanged, GoodCode: "001", BatchDate: &b1, OldQty: ptr(6), NewQty: ptr(5), OrderStatus: PickingStatusShipped},
			{Kind: PickingChangeLineRemoved, GoodCode: "001", OldQty: ptr(3), OrderStatus: PickingStatusShipped},
			{Kind: PickingChangeLineAdded, GoodCode: "002", NewQty: ptr(1), OrderStatus: PickingStatusShipped},
			{Kind: PickingChangeOrderDeleted, OrderStatus: PickingStatusShipped},
			{Kind: PickingChangeOrderRestored, OrderStatus: PickingStatusShipped},
		},
	}
	ClassifyPickingChanges(&d)
	want := []string{
		PickingChangeReasonOrder, PickingChangeReasonPicking,
		PickingChangeReasonFit, PickingChangeReasonDiverged,
		PickingChangeReasonFit, PickingChangeReasonDiverged,
		PickingChangeReasonDiverged, PickingChangeReasonFit,
	}
	for i, c := range d.Changes {
		if c.Reason != want[i] {
			t.Errorf("правка %d (%s %s): %s, ждали %s", i, c.Kind, c.OrderStatus, c.Reason, want[i])
		}
	}
}
