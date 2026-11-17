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

// Ручки заданий для склада (P5-02-1) через настоящий роутер: текущие, карточка, взятие,
// отказ и лента. Логику пула и остатка проверяют тесты репозитория; здесь - маршруты,
// коды ответов и форма JSON, на которую опирается ТСД.
func TestTasksHTTP_poolCycle(t *testing.T) {
	e := newReceivingE2E(t, nil)
	ctx := context.Background()
	good, box := uuid.NewString(), uuid.NewString()
	if _, err := e.pool.Exec(ctx, `INSERT INTO goods (id,code,name,uom) VALUES ($1::uuid,'16121','Кальмар','шт')`, good); err != nil {
		t.Fatal(err)
	}
	receipt := `{"operations":[{"operation_id":"` + uuid.NewString() + `","kind":"receipt_submit","payload":{"doc_number":"ТН-1","doc_date":"01-10-2026",
		"receipt_id":"` + uuid.NewString() + `","warehouse_id":"` + e.warehouse + `","supplier_id":"` + e.supplier + `",
		"load_units":[{"id":"` + box + `"}],
		"lines":[
			{"good_id":"` + good + `","production_date":"01-09-2026","qty":12,"load_unit_id":"` + box + `"},
			{"good_id":"` + good + `","production_date":"02-09-2026","qty":3}]}}]}`
	if got := e.operations(t, receipt); got[0] != service.StatusAccepted {
		t.Fatalf("приёмка: %v", got)
	}

	var tasks []struct {
		ID        string  `json:"id"`
		Number    int64   `json:"number"`
		Kind      string  `json:"kind"`
		Status    string  `json:"status"`
		Supplier  string  `json:"supplier"`
		DocNumber *string `json:"doc_number"`
		DocDate   *string `json:"doc_date"`
		Items     []struct {
			LoadUnitID     *string `json:"load_unit_id"`
			Contents       []any   `json:"contents"`
			ProductionDate *string `json:"production_date"`
			Remaining      *string `json:"remaining"`
		} `json:"items"`
	}
	code, raw := e.call(t, http.MethodGet, "/api/v1/tasks", e.workerToken, "")
	if code != http.StatusOK || json.Unmarshal(raw, &tasks) != nil || len(tasks) != 1 {
		t.Fatalf("GET /tasks: %d %s", code, raw)
	}
	tk := tasks[0]
	if tk.Kind != "putaway" || tk.Status != "new" || tk.Number <= 0 || tk.Supplier != "ООО «Голсера»" || len(tk.Items) != 2 {
		t.Fatalf("задание: %s", raw)
	}
	// Основание - документ поставщика приёмки (ADHOC-23).
	if tk.DocNumber == nil || *tk.DocNumber != "ТН-1" || tk.DocDate == nil || *tk.DocDate != "01-10-2026" {
		t.Errorf("документ-основание задания: %s", raw)
	}
	if tk.Items[0].LoadUnitID == nil || len(tk.Items[0].Contents) != 1 {
		t.Errorf("позиция-короб: %s", raw)
	}
	if tk.Items[1].ProductionDate == nil || *tk.Items[1].ProductionDate != "02-09-2026" || tk.Items[1].Remaining == nil {
		t.Errorf("позиция-россыпь: %s", raw)
	}

	path := "/api/v1/tasks/" + tk.ID
	if code, raw := e.call(t, http.MethodPost, path+"/take", e.workerToken, ""); code != http.StatusNoContent {
		t.Fatalf("взять: %d %s", code, raw)
	}
	// Взятое задание другому не видно и не даётся.
	if _, raw := e.call(t, http.MethodGet, "/api/v1/tasks", e.adminToken, ""); strings.TrimSpace(string(raw)) != "[]" {
		t.Errorf("другой видит взятое: %s", raw)
	}
	if code, _ := e.call(t, http.MethodPost, path+"/take", e.adminToken, ""); code != http.StatusConflict {
		t.Errorf("взять чужое: %d, ожидался 409", code)
	}
	if code, raw := e.call(t, http.MethodGet, path, e.workerToken, ""); code != http.StatusOK ||
		!json.Valid(raw) || !containsKey(raw, "sessions") {
		t.Errorf("карточка: %d %s", code, raw)
	}
	if code, _ := e.call(t, http.MethodPost, path+"/release", e.workerToken, ""); code != http.StatusNoContent {
		t.Errorf("отказаться: %d", code)
	}

	// Несуществующее и кривое - 404; кривой фильтр ленты - 400; пустая лента - [].
	if code, _ := e.call(t, http.MethodGet, "/api/v1/tasks/"+uuid.NewString(), e.workerToken, ""); code != http.StatusNotFound {
		t.Errorf("нет задания: %d", code)
	}
	if code, _ := e.call(t, http.MethodPost, "/api/v1/tasks/x/take", e.workerToken, ""); code != http.StatusNotFound {
		t.Errorf("кривой id: %d", code)
	}
	if code, _ := e.call(t, http.MethodGet, "/api/v1/tasks/completed?from=07.10.2026", e.workerToken, ""); code != http.StatusBadRequest {
		t.Errorf("кривая дата: %d", code)
	}
	if code, raw := e.call(t, http.MethodGet, "/api/v1/tasks/completed?from=2026-10-01&to=2026-10-07&kind=putaway", e.workerToken, ""); code != http.StatusOK || strings.TrimSpace(string(raw)) != "[]" {
		t.Errorf("лента: %d %s", code, raw)
	}
	if code, raw := e.call(t, http.MethodGet, "/api/v1/tasks/executors", e.workerToken, ""); code != http.StatusOK || strings.TrimSpace(string(raw)) != "[]" {
		t.Errorf("исполнители: %d %s", code, raw)
	}
}

func containsKey(raw []byte, key string) bool {
	var m map[string]json.RawMessage
	if json.Unmarshal(raw, &m) != nil {
		return false
	}
	_, ok := m[key]
	return ok
}
