package handler_test

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/google/uuid"
)

// P10-03: пересчёт через настоящий роутер — заводит старший смены (admin), задание видно в
// пуле со ссылкой на пересчёт, кладовщик берёт ячейку, сканирует её и видит позиции без
// количеств (слепой счёт), факт уходит операцией очереди, остаток приводится к факту, пересчёт
// закрывается.
func TestStocktakeScenarioHTTP(t *testing.T) {
	e := newReceivingE2E(t, nil)
	var good, batch string
	if err := e.pool.QueryRow(t.Context(), `INSERT INTO goods (name, uom) VALUES ('Лимонад', 'шт') RETURNING id::text`).
		Scan(&good); err != nil {
		t.Fatal(err)
	}
	if err := e.pool.QueryRow(t.Context(), `INSERT INTO batches (good_id, production_date) VALUES ($1::uuid, '2026-01-01')
		RETURNING id::text`, good).Scan(&batch); err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(t.Context(), `INSERT INTO stock (cell_id, good_id, batch_id, internal_warehouse_id, qty)
		SELECT $1::uuid, $2::uuid, $3::uuid, id, 5 FROM internal_warehouses WHERE is_default`, e.cell1, good, batch); err != nil {
		t.Fatal(err)
	}

	create := `{"warehouse_id":"` + e.warehouse + `","scope_kind":"good","object_ids":["` + good + `"]}`
	if code, _ := e.call(t, http.MethodPost, "/api/v1/stocktakes", e.workerToken, create); code != http.StatusForbidden {
		t.Errorf("кладовщик заводит пересчёт: код %d, ожидался 403", code)
	}
	code, raw := e.call(t, http.MethodPost, "/api/v1/stocktakes", e.adminToken, create)
	if code != http.StatusCreated {
		t.Fatalf("завести пересчёт: код %d, %s", code, raw)
	}
	var st struct {
		ID    string `json:"id"`
		Cells int    `json:"cells"`
	}
	mustJSON(t, raw, &st)

	_, raw = e.call(t, http.MethodGet, "/api/v1/tasks", e.workerToken, "")
	if !strings.Contains(string(raw), `"stocktake_id":"`+st.ID+`"`) {
		t.Errorf("задание пересчёта не видно в пуле: %s", raw)
	}

	_, raw = e.call(t, http.MethodGet, "/api/v1/stocktakes/"+st.ID+"/cells", e.workerToken, "")
	var cells struct {
		Cells []struct {
			ID      string `json:"id"`
			Address string `json:"address"`
		} `json:"cells"`
	}
	mustJSON(t, raw, &cells)
	if len(cells.Cells) != 1 || cells.Cells[0].Address != "M1-1-1-1" {
		t.Fatalf("ячейки пересчёта: %s", raw)
	}
	cell := cells.Cells[0].ID
	if code, raw := e.call(t, http.MethodPost, "/api/v1/stocktake-cells/"+cell+"/take", e.workerToken, ""); code != http.StatusNoContent {
		t.Fatalf("взять ячейку: код %d, %s", code, raw)
	}
	code, raw = e.call(t, http.MethodPost, "/api/v1/stocktake-cells/"+cell+"/start", e.workerToken, "")
	if code != http.StatusOK || !strings.Contains(string(raw), `"production_date":"01-01-2026"`) ||
		strings.Contains(string(raw), "qty") {
		t.Fatalf("скан ячейки: код %d, позиции %s — ожидались без количеств", code, raw)
	}

	statuses := e.operations(t, `{"operations":[{"operation_id":"`+uuid.NewString()+`","kind":"stocktake_cell_submit",
		"payload":{"stocktake_cell_id":"`+cell+`","loose":[{"good_id":"`+good+`","production_date":"01-01-2026","qty":3}]}}]}`)
	if len(statuses) != 1 || statuses[0] != "accepted" {
		t.Fatalf("подсчёт ячейки: %v", statuses)
	}
	var qty string
	if err := e.pool.QueryRow(t.Context(), `SELECT qty::int::text FROM stock WHERE cell_id = $1::uuid AND good_id = $2::uuid`,
		e.cell1, good).Scan(&qty); err != nil || qty != "3" {
		t.Errorf("остаток после подсчёта: %s, %v — ожидалось 3", qty, err)
	}

	if code, _ := e.call(t, http.MethodPost, "/api/v1/stocktakes/"+st.ID+"/close", e.workerToken, ""); code != http.StatusForbidden {
		t.Errorf("кладовщик закрывает пересчёт: код %d, ожидался 403", code)
	}
	code, raw = e.call(t, http.MethodPost, "/api/v1/stocktakes/"+st.ID+"/close", e.adminToken, "")
	if code != http.StatusOK || string(raw) != "{\"uncounted\":0}\n" {
		t.Errorf("закрыть пересчёт: код %d, %q", code, raw)
	}
	_, raw = e.call(t, http.MethodGet, "/api/v1/stocktakes/"+st.ID, e.adminToken, "")
	if !strings.Contains(string(raw), `"status":"closed"`) || !strings.Contains(string(raw), `"status":"counted"`) {
		t.Errorf("пересчёт после закрытия: %s", raw)
	}
}

func mustJSON(t *testing.T, raw []byte, v any) {
	t.Helper()
	if err := json.Unmarshal(raw, v); err != nil {
		t.Fatalf("разбор %s: %v", raw, err)
	}
}
