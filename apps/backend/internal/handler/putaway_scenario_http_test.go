package handler_test

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/google/uuid"

	"craftwms/internal/service"
)

// Эталон формата размещения (P5-02, P5-02-1) — серверная половина контракта; клиентская
// появится вместе с выполнением задания на ТСД (P5-03). Настоящий роутер применяет ровно это
// тело: короб и россыпь задания уезжают из ячейки приёмки «С-Н-П» по ячейкам хранения.
func TestPutawayHTTP_clientWireFormat(t *testing.T) {
	raw := readFixture(t, "putaway_submit.json")
	var pf struct {
		Operations []struct {
			Payload struct {
				TaskID      string `json:"task_id"`
				WarehouseID string `json:"warehouse_id"`
				Lines       []struct {
					LoadUnitID string `json:"load_unit_id"`
					GoodID     string `json:"good_id"`
					ToCellID   string `json:"to_cell_id"`
				} `json:"lines"`
			} `json:"payload"`
		} `json:"operations"`
	}
	if err := json.Unmarshal(raw, &pf); err != nil {
		t.Fatalf("эталон размещения не разбирается: %v", err)
	}
	p := pf.Operations[0].Payload
	box, boxTo := p.Lines[0].LoadUnitID, p.Lines[0].ToCellID
	good, looseTo := p.Lines[1].GoodID, p.Lines[1].ToCellID

	e := newReceivingE2E(t, map[string]string{"warehouse": p.WarehouseID, "cell1": looseTo})
	ctx := context.Background()
	if _, err := e.pool.Exec(ctx, `INSERT INTO goods (id,code,name,uom) VALUES ($1::uuid,'16121','Кальмар','шт')`, good); err != nil {
		t.Fatalf("товар эталона: %v", err)
	}
	if _, err := e.pool.Exec(ctx, `INSERT INTO cells (id,warehouse_id,address) VALUES ($1::uuid,$2::uuid,'M1-1-1-2')`,
		boxTo, e.warehouse); err != nil {
		t.Fatalf("ячейка эталона: %v", err)
	}

	// Приёмка кладёт короб (12) и россыпь (3) в ячейку приёмки — из неё рождается задание.
	receipt := `{"operations":[{"operation_id":"` + uuid.NewString() + `","kind":"receipt_submit","payload":{
		"receipt_id":"` + uuid.NewString() + `","warehouse_id":"` + p.WarehouseID + `",
		"load_units":[{"id":"` + box + `","kind":"box"}],
		"lines":[
			{"good_id":"` + good + `","production_date":"01-09-2026","qty":12,"load_unit_id":"` + box + `"},
			{"good_id":"` + good + `","production_date":"02-09-2026","qty":3}]}}]}`
	if got := e.operations(t, receipt); len(got) != 1 || got[0] != service.StatusAccepted {
		t.Fatalf("приёмка под эталон не применилась: %v", got)
	}
	// Идентификатор задания выдаёт сервер; эталону нужен постоянный. Позиции переезжают на
	// задание с id эталона, рождённое приёмкой — удаляется.
	for _, sql := range []string{
		`INSERT INTO warehouse_tasks (id, kind, warehouse_id) SELECT $1::uuid, kind, warehouse_id FROM warehouse_tasks`,
		`UPDATE putaway_task_items SET task_id = $1::uuid`,
		`DELETE FROM warehouse_tasks WHERE id <> $1::uuid`,
	} {
		if _, err := e.pool.Exec(ctx, sql, p.TaskID); err != nil {
			t.Fatalf("задание под эталон: %v", err)
		}
	}

	if got := e.operations(t, string(raw)); len(got) != 1 || got[0] != service.StatusAccepted {
		t.Fatalf("эталонное размещение не применилось: %v.\n"+
			"Формат разошёлся — сверьте testdata/putaway_submit.json с тем, что шлёт клиент.", got)
	}

	if d, c1, c2 := e.qtyIn(t, e.cellDefault, good), e.qtyIn(t, looseTo, good), e.qtyIn(t, boxTo, good); d != "0.000" || c1 != "3.000" || c2 != "12.000" {
		t.Fatalf("остаток после размещения: С-Н-П=%s M1-1-1-1=%s M1-1-1-2=%s, ожидалось 0 / 3 / 12", d, c1, c2)
	}
	var status string
	if err := e.pool.QueryRow(ctx, `SELECT status FROM warehouse_tasks WHERE id = $1::uuid`, p.TaskID).Scan(&status); err != nil || status != "done" {
		t.Fatalf("задание после размещения всего: %q (%v), ожидалось done", status, err)
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
