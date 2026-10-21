package handler_test

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/google/uuid"

	"craftwms/internal/service"
)

// Эталон отгрузки возврата поставщику (ADHOC-31) — серверная половина контракта. Путь целиком:
// приёмка → две проблемы на ТСД (короб — просрок, россыпь — порча) → решение офиса «возврат»
// → задание в GET /tasks с позициями → сеанс отгрузки из эталона → товар ушёл, задание
// выполнено. Идентификатор задания выдаёт сервер — в эталоне на его месте `TASK`.
func TestReturnHTTP_clientWireFormat(t *testing.T) {
	raw := string(readFixture(t, "return_submit.json"))
	var f struct {
		Operations []struct {
			Payload struct {
				WarehouseID string   `json:"warehouse_id"`
				ProblemIDs  []string `json:"problem_ids"`
			} `json:"payload"`
		} `json:"operations"`
	}
	if err := json.Unmarshal([]byte(raw), &f); err != nil || len(f.Operations[0].Payload.ProblemIDs) != 2 {
		t.Fatalf("эталон отгрузки не разбирается: %v", err)
	}
	wh := f.Operations[0].Payload.WarehouseID
	boxProblem, looseProblem := f.Operations[0].Payload.ProblemIDs[0], f.Operations[0].Payload.ProblemIDs[1]
	cell, good, lu := uuid.NewString(), uuid.NewString(), uuid.NewString()

	e := newReceivingE2E(t, map[string]string{"warehouse": wh, "cell1": cell})
	ctx := context.Background()
	var supplier string
	if err := e.pool.QueryRow(ctx, `
		WITH g AS (INSERT INTO goods (id,code,name,uom) VALUES ($1::uuid,'16121','Кальмар','шт'))
		INSERT INTO suppliers (name) VALUES ('ООО «Вкуснярики»') RETURNING id::text`, good).Scan(&supplier); err != nil {
		t.Fatalf("товар и поставщик: %v", err)
	}
	receipt := jsonf(`{"operations":[{"operation_id":%q,"kind":"receipt_submit","payload":{
		"receipt_id":%q,"warehouse_id":%q,"doc_number":"ТН-1","doc_date":"01-10-2026",
		"load_units":[{"id":%q,"kind":"box"}],
		"lines":[
			{"good_id":%q,"production_date":"01-09-2026","qty":12,"load_unit_id":%q,"cell_id":%q},
			{"good_id":%q,"production_date":"01-09-2026","qty":5,"cell_id":%q}]}}]}`,
		uuid.NewString(), uuid.NewString(), wh, lu, good, lu, cell, good, cell)
	if got := e.operations(t, receipt); len(got) != 1 || got[0] != service.StatusAccepted {
		t.Fatalf("приёмка: %v", got)
	}
	var defect string
	if err := e.pool.QueryRow(ctx, `SELECT id::text FROM internal_warehouses WHERE code = 'DEFECT'`).Scan(&defect); err != nil {
		t.Fatalf("склад брака: %v", err)
	}
	problems := jsonf(`{"operations":[
		{"operation_id":%q,"kind":"problem_submit","payload":{"problem_id":%q,"warehouse_id":%q,
		 "load_unit_id":%q,"to_internal_warehouse_id":%q,"reason":"expired"}},
		{"operation_id":%q,"kind":"problem_submit","payload":{"problem_id":%q,"warehouse_id":%q,
		 "good_id":%q,"production_date":"01-09-2026","qty":2,"cell_id":%q,
		 "to_internal_warehouse_id":%q,"reason":"spoilage"}}]}`,
		uuid.NewString(), boxProblem, wh, lu, defect,
		uuid.NewString(), looseProblem, wh, good, cell, defect)
	if got := e.operations(t, problems); len(got) != 2 || got[0] != service.StatusAccepted || got[1] != service.StatusAccepted {
		t.Fatalf("проблемы: %v", got)
	}
	for _, id := range []string{boxProblem, looseProblem} {
		if code, body := e.call(t, http.MethodPost, "/api/v1/problems/"+id+"/resolve", e.adminToken,
			`{"decision":"supplier_return","supplier_id":"`+supplier+`"}`); code != http.StatusNoContent {
			t.Fatalf("решение «возврат»: %d %s", code, body)
		}
	}

	// ТСД видит задание возврата: поставщик и две позиции с ячейкой и проблемой-основанием.
	code, body := e.call(t, http.MethodGet, "/api/v1/tasks", e.workerToken, "")
	var tasks []struct {
		ID       string `json:"id"`
		Kind     string `json:"kind"`
		Supplier string `json:"supplier"`
		Items    []struct {
			ProblemID  string `json:"problem_id"`
			Cell       string `json:"cell"`
			LoadUnitID string `json:"load_unit_id"`
			Placed     bool   `json:"placed"`
		} `json:"items"`
	}
	if code != http.StatusOK || json.Unmarshal(body, &tasks) != nil {
		t.Fatalf("задания: %d %s", code, body)
	}
	var task string
	for _, tk := range tasks {
		if tk.Kind == "supplier_return" {
			task = tk.ID
			if tk.Supplier != "ООО «Вкуснярики»" || len(tk.Items) != 2 || tk.Items[0].Cell != "M1-1-1-1" ||
				tk.Items[0].ProblemID == "" || tk.Items[0].Placed {
				t.Fatalf("задание возврата: %s", body)
			}
		}
	}
	if task == "" {
		t.Fatalf("задания возврата нет в GET /tasks: %s", body)
	}

	batch := strings.Replace(raw, `"TASK"`, `"`+task+`"`, 1)
	if got := e.operations(t, batch); len(got) != 1 || got[0] != service.StatusAccepted {
		t.Fatalf("эталонная отгрузка не применилась: %v.\n"+
			"Формат разошёлся — сверьте testdata/return_submit.json с тем, что шлёт клиент.", got)
	}
	// Ушли 14 (короб 12 + россыпь 2), осталось 3 основной россыпи; задание выполнено.
	var left, status string
	if err := e.pool.QueryRow(ctx, `
		SELECT COALESCE(sum(qty), 0)::text FROM stock WHERE cell_id = $1::uuid`, cell).Scan(&left); err != nil || left != "3.000" {
		t.Fatalf("остаток после отгрузки: %q (%v)", left, err)
	}
	if err := e.pool.QueryRow(ctx, `SELECT status FROM warehouse_tasks WHERE id = $1::uuid`, task).Scan(&status); err != nil || status != "done" {
		t.Fatalf("задание после отгрузки: %q (%v)", status, err)
	}
	// Повтор сеанса новой операцией — отказ по существу: сеанс уже проведён.
	again := strings.Replace(batch, "7f000000-0000-4000-8000-0000000000f1", uuid.NewString(), 1)
	if got := e.operations(t, again); len(got) != 1 || got[0] != service.StatusRejected {
		t.Fatalf("повтор сеанса: %v", got)
	}
}
