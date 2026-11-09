package repository_test

import (
	"context"
	"reflect"
	"testing"

	"github.com/google/uuid"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// Короб ЧЗ фикстуры возврата (CZ-07): обе марки воды — в групповой упаковке внутри короба ЧЗ,
// короб — ГЕ в A-1.
const (
	czShipBox   = "00046000000000000099"
	czShipGroup = "0104600000000017215GRP01"
)

// czBoxFixture перекладывает марки воды фикстуры возврата в короб ЧЗ с групповой упаковкой и
// возвращает ГЕ короба.
func czBoxFixture(f *returnFixture) string {
	lu := f.scan(`INSERT INTO load_units (id,kind,cell_id,status) VALUES (gen_random_uuid(),'box',$1,'placed') RETURNING id::text`, f.cellA)
	mbatch := f.scan(`SELECT id::text FROM batches WHERE good_id = $1`, f.marked)
	f.exec(`INSERT INTO lu_content (load_unit_id,good_id,batch_id,qty) VALUES ($1,$2,$3,2)`, lu, f.marked, mbatch)
	f.exec(`INSERT INTO cz_aggregates (code,kind,load_unit_id) VALUES ($1,'BOX',$2)`, czShipBox, lu)
	f.exec(`INSERT INTO cz_aggregates (code,kind,parent_code) VALUES ($1,'GROUP',$2)`, czShipGroup, czShipBox)
	f.exec(`UPDATE cz_marks SET load_unit_id = $1, cell_id = NULL, internal_warehouse_id = NULL, aggregate_code = $2
		WHERE cis = ANY($3::text[])`, lu, czShipGroup, []string{f.mark1, f.mark2})
	return lu
}

// opened — вскрыта ли упаковка ЧЗ.
func (f *returnFixture) opened(code string) bool {
	return f.scan(`SELECT (opened_at IS NOT NULL)::text FROM cz_aggregates WHERE code = $1`, code) == "true"
}

// TestPickingCZBoxes — целый короб ЧЗ в сборке (CZ-07).
//
// Короб ЧЗ, целиком легший в один короб отгрузки, после «Завершить сборку» не вскрыт, и детали
// заказа (выгрузка Excel) числят его целым — коробом, без вложенной упаковки. Возврат его марки на
// место вскрывает короб, и в деталях он уже россыпью. Марки короба, разложенные по двум коробам
// отгрузки, вскрывают его на завершении.
func TestPickingCZBoxes(t *testing.T) {
	ctx := context.Background()
	start := func(f *returnFixture) (order, line, mline, box1, box2 string) {
		t.Helper()
		order, line, mline = f.order("15512")
		if err := f.pk.TakeOrder(ctx, order, f.user, 0); err != nil {
			t.Fatalf("взять заказ: %v", err)
		}
		box1, box2 = uuid.NewString(), uuid.NewString()
		for _, b := range []string{box1, box2} {
			if _, err := f.pk.AddBox(ctx, order, f.user, b); err != nil {
				t.Fatalf("короб отгрузки: %v", err)
			}
		}
		f.pick(order, repository.PickingPickInput{LineID: line, BoxID: box1, SourceCellID: f.cellA, Qty: decimal.NewFromInt(8)})
		return order, line, mline, box1, box2
	}
	czBoxes := func(f *returnFixture, order string) []model.PickingCZBox {
		t.Helper()
		d, err := f.pk.PortalOrder(ctx, order)
		if err != nil {
			t.Fatalf("детали заказа: %v", err)
		}
		return d.CZBoxes
	}

	t.Run("короб целиком", func(t *testing.T) {
		f := newReturnFixture(t)
		lu := czBoxFixture(f)
		order, line, mline, _, box2 := start(f)
		water := f.pick(order, repository.PickingPickInput{LineID: mline, BoxID: box2, SourceLoadUnitID: lu,
			Qty: decimal.NewFromInt(2), Marks: []string{f.mark1, f.mark2}})
		if _, err := f.pk.CompleteOrder(ctx, order, f.user); err != nil {
			t.Fatalf("завершить: %v", err)
		}
		if f.opened(czShipBox) || f.opened(czShipGroup) {
			t.Fatal("целый короб ЧЗ вскрыт на завершении сборки")
		}
		want := []model.PickingCZBox{{Code: czShipBox, Kind: model.CZAggregateBox, Marks: []string{f.mark1, f.mark2}}}
		if got := czBoxes(f, order); !reflect.DeepEqual(got, want) {
			t.Fatalf("целые упаковки: %+v", got)
		}

		// Реестр убрал воду: одна марка вернулась в C-1 — короб вскрыт, в деталях россыпь.
		gid := f.good
		f.reload(model.PickingOrderPlan{
			Kind: model.PickingOrderChanged, ExistingID: order, Status: model.PickingStatusPicked,
			Header:         &model.PickingOrderHeader{InvoiceNumber: "20961", OrderNumber: "15512"},
			Lines:          []model.PickingPlanLine{{ExistingID: line, GoodCode: "00000016147", GoodName: "Лимонад", GoodID: &gid, Qty: 8}},
			RemovedLineIDs: []string{mline},
		})
		if err := f.returnPick(water, f.cellC, 1, f.mark1); err != nil {
			t.Fatalf("вернуть марку: %v", err)
		}
		if !f.opened(czShipBox) || !f.opened(czShipGroup) {
			t.Fatal("возврат марки не вскрыл короб ЧЗ")
		}
		if got := czBoxes(f, order); len(got) != 0 {
			t.Fatalf("вскрытый короб числится целым: %+v", got)
		}
	})

	t.Run("по двум коробам отгрузки", func(t *testing.T) {
		f := newReturnFixture(t)
		lu := czBoxFixture(f)
		order, _, mline, box1, box2 := start(f)
		f.pick(order, repository.PickingPickInput{LineID: mline, BoxID: box1, SourceLoadUnitID: lu,
			Qty: decimal.NewFromInt(1), Marks: []string{f.mark1}})
		f.pick(order, repository.PickingPickInput{LineID: mline, BoxID: box2, SourceLoadUnitID: lu,
			Qty: decimal.NewFromInt(1), Marks: []string{f.mark2}})
		if _, err := f.pk.CompleteOrder(ctx, order, f.user); err != nil {
			t.Fatalf("завершить: %v", err)
		}
		if !f.opened(czShipBox) || !f.opened(czShipGroup) {
			t.Fatal("короб ЧЗ, разложенный по двум коробам отгрузки, не вскрыт")
		}
		if got := czBoxes(f, order); len(got) != 0 {
			t.Fatalf("вскрытый короб числится целым: %+v", got)
		}
	})
}
