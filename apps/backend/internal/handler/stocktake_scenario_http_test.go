package handler_test

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
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
	if !strings.Contains(string(raw), `"stocktake_id":"`+st.ID+`"`) ||
		!strings.Contains(string(raw), `"scope_kind":"good","created_by":"Оператор","cells":1,"counted":0`) {
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

	// P10-05: список пересчётов для портала и документ «Инвентаризация» для 1С.
	if code, _ := e.call(t, http.MethodGet, "/api/v1/stocktakes", e.workerToken, ""); code != http.StatusForbidden {
		t.Errorf("список пересчётов кладовщику: код %d, ожидался 403", code)
	}
	_, raw = e.call(t, http.MethodGet, "/api/v1/stocktakes?status=closed", e.adminToken, "")
	if !strings.Contains(string(raw), `"id":"`+st.ID+`"`) || !strings.Contains(string(raw), `"cells":1,"counted":1`) {
		t.Errorf("закрытые пересчёты: %s", raw)
	}
	_, raw = e.call(t, http.MethodGet, "/api/v1/documents?kind=stocktake", e.adminToken, "")
	var docs []struct {
		ID              string `json:"id"`
		StocktakeNumber int64  `json:"stocktake_number"`
		LinesCount      int    `json:"lines_count"`
	}
	mustJSON(t, raw, &docs)
	if len(docs) != 1 || docs[0].StocktakeNumber == 0 || docs[0].LinesCount != 1 {
		t.Fatalf("документы «Инвентаризация»: %s", raw)
	}
	if code, file := e.call(t, http.MethodGet, "/api/v1/documents/"+docs[0].ID+"/file.xlsx", e.adminToken, ""); code != http.StatusOK || len(file) == 0 {
		t.Errorf("файл «Инвентаризации»: код %d, %d байт", code, len(file))
	}
}

func mustJSON(t *testing.T, raw []byte, v any) {
	t.Helper()
	if err := json.Unmarshal(raw, v); err != nil {
		t.Fatalf("разбор %s: %v", raw, err)
	}
}

// P10-04: эталон формата stocktake_cell_submit — тело, которое собирает ТСД, — применяется
// настоящим роутером: короб найден, россыпь приведена к факту, марка найдена. Идентификатор
// ячейки пересчёта выдаёт сервер — в эталоне на его месте `CELL`.
func TestStocktakeCellSubmitFixture(t *testing.T) {
	e := newReceivingE2E(t, nil)
	const (
		good  = "7f000000-0000-4000-8000-0000000000b1"
		good2 = "7f000000-0000-4000-8000-0000000000b2"
		box   = "7f000000-0000-4000-8000-0000000000c1"
		mark  = "0104600000000017215S1"
	)
	for _, sql := range []string{
		`INSERT INTO goods (id, name, uom) VALUES ('` + good + `', 'Лимонад', 'шт')`,
		`INSERT INTO goods (id, name, uom, cz_marked) VALUES ('` + good2 + `', 'Снек', 'шт', true)`,
		`INSERT INTO batches (good_id, production_date) VALUES ('` + good + `', '2026-01-01'), ('` + good2 + `', '2026-02-01')`,
		`INSERT INTO load_units (id, kind, cell_id, status) VALUES ('` + box + `', 'box', '` + e.cell1 + `', 'placed')`,
		`INSERT INTO lu_content (load_unit_id, good_id, batch_id, qty)
		 SELECT '` + box + `', good_id, id, 6 FROM batches WHERE good_id = '` + good + `'`,
		`INSERT INTO stock (cell_id, good_id, batch_id, internal_warehouse_id, qty)
		 SELECT '` + e.cell1 + `', b.good_id, b.id, w.id, CASE WHEN b.good_id = '` + good + `' THEN 11 ELSE 1 END
		 FROM batches b, internal_warehouses w WHERE w.is_default`,
		`INSERT INTO cz_marks (cis, good_id, batch_id, cell_id, internal_warehouse_id)
		 SELECT '` + mark + `', b.good_id, b.id, '` + e.cell1 + `', w.id
		 FROM batches b, internal_warehouses w WHERE w.is_default AND b.good_id = '` + good2 + `'`,
	} {
		if _, err := e.pool.Exec(t.Context(), sql); err != nil {
			t.Fatalf("seed %q: %v", sql, err)
		}
	}

	code, raw := e.call(t, http.MethodPost, "/api/v1/stocktakes", e.adminToken,
		`{"warehouse_id":"`+e.warehouse+`","scope_kind":"cells","object_ids":["`+e.cell1+`"]}`)
	if code != http.StatusCreated {
		t.Fatalf("завести пересчёт: %d %s", code, raw)
	}
	var st struct {
		ID string `json:"id"`
	}
	mustJSON(t, raw, &st)
	_, raw = e.call(t, http.MethodGet, "/api/v1/stocktakes/"+st.ID+"/cells", e.workerToken, "")
	var cells struct {
		Cells []struct {
			ID string `json:"id"`
		} `json:"cells"`
	}
	mustJSON(t, raw, &cells)
	cell := cells.Cells[0].ID
	e.call(t, http.MethodPost, "/api/v1/stocktake-cells/"+cell+"/take", e.workerToken, "")
	if code, raw := e.call(t, http.MethodPost, "/api/v1/stocktake-cells/"+cell+"/start", e.workerToken, ""); code != http.StatusOK {
		t.Fatalf("скан ячейки: %d %s", code, raw)
	}

	fixture, err := os.ReadFile(filepath.Join("testdata", "stocktake_cell_submit.json"))
	if err != nil {
		t.Fatal(err)
	}
	statuses := e.operations(t, strings.ReplaceAll(string(fixture), "CELL", cell))
	if len(statuses) != 1 || statuses[0] != "accepted" {
		t.Fatalf("эталон подсчёта: %v", statuses)
	}
	var loose string
	if err := e.pool.QueryRow(t.Context(), `SELECT qty::int::text FROM stock
		WHERE cell_id = $1::uuid AND good_id = $2::uuid`, e.cell1, good).Scan(&loose); err != nil || loose != "9" {
		t.Errorf("остаток лимонада: %s, %v — ожидалось 9 (3 россыпью + 6 в коробе)", loose, err)
	}
	var found bool
	if err := e.pool.QueryRow(t.Context(), `SELECT found FROM stocktake_marks WHERE cis = $1`, mark).
		Scan(&found); err != nil || !found {
		t.Errorf("марка не найдена: %v", err)
	}
}
