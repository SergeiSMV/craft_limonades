package handler_test

import (
	"context"
	"encoding/json"
	"net/http"
	"reflect"
	"strings"
	"testing"

	"github.com/google/uuid"

	"craftwms/internal/service"
)

// Эталон проблемы склада (P6-07-1) — серверная половина контракта; клиентская появится вместе
// с диалогом фиксации на ТСД (P6-07-2). Две операции: 2 шт россыпи — в «Брак» с комментарием,
// короб целиком — в «Изолятор» с маркой ЧЗ.
//
// Идентификаторы внутренних складов выдаёт сервер, поэтому в эталоне на их месте коды
// справочника (DEFECT, ISOLATOR) — тест подставляет id, как их взял бы клиент из
// GET /internal-warehouses.
func TestProblemHTTP_clientWireFormat(t *testing.T) {
	raw := string(readFixture(t, "problem_submit.json"))
	var f struct {
		Operations []struct {
			Payload struct {
				WarehouseID string `json:"warehouse_id"`
				GoodID      string `json:"good_id"`
				CellID      string `json:"cell_id"`
				LoadUnitID  string `json:"load_unit_id"`
			} `json:"payload"`
		} `json:"operations"`
	}
	if err := json.Unmarshal([]byte(raw), &f); err != nil {
		t.Fatalf("эталон проблемы не разбирается: %v", err)
	}
	loose, box := f.Operations[0].Payload, f.Operations[1].Payload
	cell, good, lu := loose.CellID, loose.GoodID, box.LoadUnitID

	e := newReceivingE2E(t, map[string]string{"warehouse": loose.WarehouseID, "cell1": cell})
	ctx := context.Background()
	if _, err := e.pool.Exec(ctx, `INSERT INTO goods (id,code,name,uom) VALUES ($1::uuid,'16121','Кальмар','шт')`, good); err != nil {
		t.Fatalf("товар эталона: %v", err)
	}
	// Приёмка кладёт сразу в ячейку хранения M1-1-1-1 короб 12 и россыпь 5 одной партии.
	receipt := jsonf(`{"operations":[{"operation_id":%q,"kind":"receipt_submit","payload":{
		"receipt_id":%q,"warehouse_id":%q,"doc_number":"ТН-1","doc_date":"01-10-2026",
		"load_units":[{"id":%q,"kind":"box"}],
		"lines":[
			{"good_id":%q,"production_date":"01-09-2026","qty":12,"load_unit_id":%q,"cell_id":%q},
			{"good_id":%q,"production_date":"01-09-2026","qty":5,"cell_id":%q}]}}]}`,
		uuid.NewString(), uuid.NewString(), loose.WarehouseID, lu, good, lu, cell, good, cell)
	if got := e.operations(t, receipt); len(got) != 1 || got[0] != service.StatusAccepted {
		t.Fatalf("приёмка под эталон не применилась: %v", got)
	}

	// Справочник складов для ТСД: «Основной» первым, «Брак» и «Изолятор» — на выбор.
	code, body := e.call(t, http.MethodGet, "/api/v1/internal-warehouses", e.workerToken, "")
	var iws []struct {
		ID        string `json:"id"`
		Code      string `json:"code"`
		IsDefault bool   `json:"is_default"`
	}
	if code != http.StatusOK || json.Unmarshal(body, &iws) != nil || len(iws) < 3 || !iws[0].IsDefault {
		t.Fatalf("внутренние склады: %d %s", code, body)
	}
	ids := map[string]string{}
	for _, w := range iws {
		ids[w.Code] = w.ID
	}
	batch := strings.NewReplacer(`"DEFECT"`, `"`+ids["DEFECT"]+`"`, `"ISOLATOR"`, `"`+ids["ISOLATOR"]+`"`).Replace(raw)

	if got := e.operations(t, batch); len(got) != 2 || got[0] != service.StatusAccepted || got[1] != service.StatusAccepted {
		t.Fatalf("эталонные проблемы не применились: %v.\n"+
			"Формат разошёлся — сверьте testdata/problem_submit.json с тем, что шлёт клиент.", got)
	}

	// Количество в ячейке то же (17): 3 основной россыпи, 2 брака, 12 изолятора в коробе.
	var split string
	if err := e.pool.QueryRow(ctx, `
		SELECT string_agg(w.code || ':' || s.qty::text, ' ' ORDER BY w.code)
		FROM stock s JOIN internal_warehouses w ON w.id = s.internal_warehouse_id
		WHERE s.cell_id = $1::uuid AND s.qty > 0`, cell).Scan(&split); err != nil || split != "DEFECT:2.000 ISOLATOR:12.000 MAIN:3.000" {
		t.Fatalf("остаток по складам: %q (%v)", split, err)
	}
	code, body = e.call(t, http.MethodGet, "/api/v1/cells/"+cell+"/contents", e.workerToken, "")
	var contents struct {
		LoadUnits []struct {
			InternalWarehouseID string `json:"internal_warehouse_id"`
		} `json:"load_units"`
	}
	if code != http.StatusOK || json.Unmarshal(body, &contents) != nil || len(contents.LoadUnits) != 1 ||
		contents.LoadUnits[0].InternalWarehouseID != ids["ISOLATOR"] {
		t.Fatalf("короб в содержимом ячейки: %d %s", code, body)
	}

	// Та же проблема повторно (новая операция, тот же problem_id) — отказ по существу.
	again := strings.Replace(batch, "7e000000-0000-4000-8000-0000000000f1", uuid.NewString(), 1)
	again = strings.Replace(again, "7e000000-0000-4000-8000-0000000000f2", uuid.NewString(), 1)
	if got := e.operations(t, again); len(got) != 2 || got[0] != service.StatusRejected {
		t.Fatalf("повтор проблемы: %v", got)
	}

	// ADHOC-35: «Текущие» — кладовщик видит обе открытые проблемы.
	code, body = e.call(t, http.MethodGet, "/api/v1/problems/current", e.workerToken, "")
	var current []struct {
		ID     string `json:"id"`
		Status string `json:"status"`
	}
	if code != http.StatusOK || json.Unmarshal(body, &current) != nil || len(current) != 2 ||
		current[0].Status != "open" {
		t.Fatalf("текущие: %d %s", code, body)
	}

	// ADHOC-34: офис списывает россыпь — кладовщик видит её в ленте «Завершённые» в формате
	// эталона testdata/problems_resolved.json; открытая (короб в «Изоляторе») туда не попадает,
	// рабочий список офиса кладовщику закрыт.
	if code, body := e.call(t, http.MethodPost, "/api/v1/problems/7e000000-0000-4000-8000-000000000001/resolve",
		e.adminToken, `{"resolution_id":"7b000000-0000-4000-8000-000000000001","doc_number":"СП-17","doc_date":"2026-10-21"}`); code != http.StatusNoContent {
		t.Fatalf("решение офиса: %d %s", code, body)
	}
	code, body = e.call(t, http.MethodGet, "/api/v1/problems/current", e.workerToken, "")
	if code != http.StatusOK || json.Unmarshal(body, &current) != nil || len(current) != 1 ||
		current[0].ID != "7e000000-0000-4000-8000-000000000002" {
		t.Fatalf("решённая ушла из текущих: %d %s", code, body)
	}
	if code, _ := e.call(t, http.MethodGet, "/api/v1/problems", e.workerToken, ""); code != http.StatusForbidden {
		t.Errorf("рабочий список офиса кладовщику: %d", code)
	}
	code, body = e.call(t, http.MethodGet, "/api/v1/problems/resolved", e.workerToken, "")
	if code != http.StatusOK {
		t.Fatalf("лента решённых: %d %s", code, body)
	}
	var want, got any
	if err := json.Unmarshal(readFixture(t, "problems_resolved.json"), &want); err != nil {
		t.Fatalf("эталон ленты не разбирается: %v", err)
	}
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("ответ ленты не разбирается: %v", err)
	}
	// Моменты и ФИО выдаёт сервер — эталон их знать не может.
	volatile := map[string]bool{"created_at": true, "resolved_at": true, "created_by": true, "resolved_by": true}
	blank(want, volatile)
	blank(got, volatile)
	if !reflect.DeepEqual(got, want) {
		g, _ := json.MarshalIndent(got, "", "  ")
		t.Fatalf("лента разошлась с эталоном testdata/problems_resolved.json — сверьте формат "+
			"с тем, что разбирает клиент.\nПолучено: %s", g)
	}
}
