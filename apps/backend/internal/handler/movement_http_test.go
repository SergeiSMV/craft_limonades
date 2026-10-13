package handler_test

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/google/uuid"

	"craftwms/internal/service"
)

// Эталон формата движения (P6-03) — серверная половина контракта; клиентская появится вместе
// с потоком перемещения на ТСД (P6-04). Настоящий роутер применяет ровно это тело: короб
// целиком переезжает в M1-1-1-2, товар из второго короба ложится россыпью в M1-1-1-1, россыпь
// ячейки приёмки докладывается в переехавший короб.
func TestMovementHTTP_clientWireFormat(t *testing.T) {
	raw := readFixture(t, "movement_submit.json")
	var mf struct {
		Operations []struct {
			Payload struct {
				WarehouseID string `json:"warehouse_id"`
				Lines       []struct {
					LoadUnitID     string `json:"load_unit_id"`
					GoodID         string `json:"good_id"`
					FromCellID     string `json:"from_cell_id"`
					FromLoadUnitID string `json:"from_load_unit_id"`
					ToCellID       string `json:"to_cell_id"`
				} `json:"lines"`
			} `json:"payload"`
		} `json:"operations"`
	}
	if err := json.Unmarshal(raw, &mf); err != nil {
		t.Fatalf("эталон движения не разбирается: %v", err)
	}
	p := mf.Operations[0].Payload
	box1, cell2 := p.Lines[0].LoadUnitID, p.Lines[0].ToCellID
	good, box2, cell1 := p.Lines[1].GoodID, p.Lines[1].FromLoadUnitID, p.Lines[1].ToCellID
	receiving := p.Lines[2].FromCellID

	e := newReceivingE2E(t, map[string]string{"warehouse": p.WarehouseID, "cell1": cell1, "cell_default": receiving})
	ctx := context.Background()
	if _, err := e.pool.Exec(ctx, `INSERT INTO goods (id,code,name,uom) VALUES ($1::uuid,'16121','Кальмар','шт')`, good); err != nil {
		t.Fatalf("товар эталона: %v", err)
	}
	if _, err := e.pool.Exec(ctx, `INSERT INTO cells (id,warehouse_id,address) VALUES ($1::uuid,$2::uuid,'M1-1-1-2')`,
		cell2, e.warehouse); err != nil {
		t.Fatalf("ячейка эталона: %v", err)
	}

	// Приёмка кладёт в ячейку приёмки два короба по 12 и россыпь 5 одной партии.
	receipt := jsonf(`{"operations":[{"operation_id":%q,"kind":"receipt_submit","payload":{
		"receipt_id":%q,"warehouse_id":%q,"doc_number":"ТН-1","doc_date":"01-10-2026",
		"load_units":[{"id":%q,"kind":"box"},{"id":%q,"kind":"box"}],
		"lines":[
			{"good_id":%q,"production_date":"01-09-2026","qty":12,"load_unit_id":%q},
			{"good_id":%q,"production_date":"01-09-2026","qty":12,"load_unit_id":%q},
			{"good_id":%q,"production_date":"01-09-2026","qty":5}]}}]}`,
		uuid.NewString(), uuid.NewString(), p.WarehouseID, box1, box2, good, box1, good, box2, good)
	if got := e.operations(t, receipt); len(got) != 1 || got[0] != service.StatusAccepted {
		t.Fatalf("приёмка под эталон не применилась: %v", got)
	}

	if got := e.operations(t, string(raw)); len(got) != 1 || got[0] != service.StatusAccepted {
		t.Fatalf("эталонное движение не применилось: %v.\n"+
			"Формат разошёлся — сверьте testdata/movement_submit.json с тем, что шлёт клиент.", got)
	}

	// С-Н-П: 29 − короб 12 − 3 из второго короба − 2 россыпи = 12 (второй короб 9 + россыпь 3).
	if d, c1, c2 := e.qtyIn(t, e.cellDefault, good), e.qtyIn(t, cell1, good), e.qtyIn(t, cell2, good); d != "12.000" || c1 != "3.000" || c2 != "14.000" {
		t.Fatalf("остаток после движения: С-Н-П=%s M1-1-1-1=%s M1-1-1-2=%s, ожидалось 12 / 3 / 14", d, c1, c2)
	}
	var contents string
	if err := e.pool.QueryRow(ctx, `SELECT string_agg(qty::text, ' ' ORDER BY load_unit_id = $2::uuid DESC)
		FROM lu_content WHERE load_unit_id IN ($1::uuid, $2::uuid)`, box2, box1).Scan(&contents); err != nil || contents != "14.000 9.000" {
		t.Fatalf("состав коробов: %q (%v), ожидалось 14 (переехавший) и 9", contents, err)
	}
}
