package handler_test

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"craftwms/internal/service"
)

// Эталон формата размещения (P5-02) — серверная половина контракта; клиентская появится вместе
// с потоком размещения на ТСД (P5-03). Настоящий роутер применяет ровно это тело поверх приёмки
// из эталона receipt_submit.json: короб уезжает из своей ячейки в другую, россыпь — из ячейки
// приёмки «С-Н-П».
func TestPutawayHTTP_clientWireFormat(t *testing.T) {
	receipt := readFixture(t, "receipt_submit.json")
	putaway := readFixture(t, "putaway_submit.json")

	var rf struct {
		Operations []struct {
			Payload struct {
				WarehouseID string `json:"warehouse_id"`
				SupplierID  string `json:"supplier_id"`
				Lines       []struct {
					GoodID string `json:"good_id"`
					CellID string `json:"cell_id"`
				} `json:"lines"`
			} `json:"payload"`
		} `json:"operations"`
	}
	var pf struct {
		Operations []struct {
			Payload struct {
				Lines []struct {
					LoadUnitID string `json:"load_unit_id"`
					ToCellID   string `json:"to_cell_id"`
				} `json:"lines"`
			} `json:"payload"`
		} `json:"operations"`
	}
	if err := json.Unmarshal(receipt, &rf); err != nil {
		t.Fatalf("эталон приёмки не разбирается: %v", err)
	}
	if err := json.Unmarshal(putaway, &pf); err != nil {
		t.Fatalf("эталон размещения не разбирается: %v", err)
	}
	rp, pl := rf.Operations[0].Payload, pf.Operations[0].Payload.Lines
	e := newReceivingE2E(t, map[string]string{
		"warehouse": rp.WarehouseID, "supplier": rp.SupplierID, "cell1": rp.Lines[0].CellID,
	})
	box, boxTo := pl[0].LoadUnitID, pl[0].ToCellID
	ctx := context.Background()
	if _, err := e.pool.Exec(ctx, `INSERT INTO goods (id,code,name,uom) VALUES ($1::uuid,'16121','Кальмар','шт')`,
		rp.Lines[0].GoodID); err != nil {
		t.Fatalf("товар эталона: %v", err)
	}
	if _, err := e.pool.Exec(ctx, `INSERT INTO cells (id,warehouse_id,address) VALUES ($1::uuid,$2::uuid,'M1-1-1-2')`,
		boxTo, e.warehouse); err != nil {
		t.Fatalf("ячейка эталона: %v", err)
	}

	if got := e.operations(t, string(receipt)); len(got) != 1 || got[0] != service.StatusAccepted {
		t.Fatalf("эталонная приёмка не применилась: %v", got)
	}
	if got := e.operations(t, string(putaway)); len(got) != 1 || got[0] != service.StatusAccepted {
		t.Fatalf("эталонное размещение не применилось: %v.\n"+
			"Формат разошёлся — сверьте testdata/putaway_submit.json с тем, что шлёт клиент.", got)
	}

	good := rp.Lines[0].GoodID
	// Короб (12) уехал из M1-1-1-1 в M1-1-1-2, россыпь (3) — из «С-Н-П» в M1-1-1-1.
	if d, c1, c2 := e.qtyIn(t, e.cellDefault, good), e.qtyIn(t, e.cell1, good), e.qtyIn(t, boxTo, good); d != "0.000" || c1 != "3.000" || c2 != "12.000" {
		t.Fatalf("остаток после размещения: С-Н-П=%s M1-1-1-1=%s M1-1-1-2=%s, ожидалось 0 / 3 / 12", d, c1, c2)
	}
	var cell string
	if err := e.pool.QueryRow(ctx, `SELECT cell_id::text FROM load_units WHERE id = $1::uuid`, box).Scan(&cell); err != nil || cell != boxTo {
		t.Fatalf("место короба: %q (%v), ожидалась M1-1-1-2", cell, err)
	}
}

// readFixture читает эталон из testdata.
func readFixture(t *testing.T, name string) []byte {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatalf("эталон %s не читается: %v", name, err)
	}
	return raw
}
