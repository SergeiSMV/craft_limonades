package handler_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"craftwms/internal/auth"
	"craftwms/internal/model"
	"craftwms/internal/service"
)

// Эталон снимка для кэша ТСД (P5-05) - серверная половина контракта. Приёмка с id эталона
// кладёт короб (12) в ячейку хранения и россыпь (3) в ячейку приёмки; ответ снимка обязан
// совпасть с testdata/contents_snapshot.json. Клиентская половина разбирает тот же файл.
//
// Не сравниваются значения, которых эталон знать не может: момент снимка, время создания
// короба, идентификаторы партий и внутреннего склада - их выдаёт сервер.
func TestContentsHTTP_snapshotWireFormat(t *testing.T) {
	raw := readFixture(t, "contents_snapshot.json")
	var want map[string]any
	if err := json.Unmarshal(raw, &want); err != nil {
		t.Fatalf("эталон снимка не разбирается: %v", err)
	}
	lu := want["load_units"].([]any)[0].(map[string]any)
	loose := want["loose"].([]any)[0].(map[string]any)
	box, boxCell := lu["id"].(string), lu["cell_id"].(string)
	good, looseCell := loose["good_id"].(string), loose["cell_id"].(string)

	e := newReceivingE2E(t, map[string]string{"cell_default": looseCell, "cell1": boxCell})
	if _, err := e.pool.Exec(context.Background(),
		`INSERT INTO goods (id,code,name,uom) VALUES ($1::uuid,'16121','Кальмар','шт')`, good); err != nil {
		t.Fatalf("товар эталона: %v", err)
	}
	receipt := `{"operations":[{"operation_id":"` + uuid.NewString() + `","kind":"receipt_submit","payload":{"doc_number":"ТН-1","doc_date":"01-10-2026",
		"receipt_id":"` + uuid.NewString() + `","warehouse_id":"` + e.warehouse + `",
		"load_units":[{"id":"` + box + `","kind":"box"}],
		"lines":[
			{"good_id":"` + good + `","production_date":"01-09-2026","qty":12,"load_unit_id":"` + box + `","cell_id":"` + boxCell + `"},
			{"good_id":"` + good + `","production_date":"02-09-2026","qty":3}]}}]}`
	if got := e.operations(t, receipt); len(got) != 1 || got[0] != service.StatusAccepted {
		t.Fatalf("приёмка под эталон не применилась: %v", got)
	}
	// Короб эталона - короб ЧЗ с маркой внутри, вторая марка - в россыпи (CZ-06). Пишутся
	// прямо в базу: приёмка короба ЧЗ требует ответа ЧЗ, а проверяется здесь формат снимка.
	marks := want["marks"].([]any)
	boxMark, looseMark := marks[0].(map[string]any), marks[1].(map[string]any)
	if _, err := e.pool.Exec(context.Background(), `
		INSERT INTO cz_aggregates (code, kind, load_unit_id) VALUES ($1, 'BOX', $2::uuid);
	`, lu["cz_code"], box); err != nil {
		t.Fatalf("короб ЧЗ эталона: %v", err)
	}
	if _, err := e.pool.Exec(context.Background(), `
		INSERT INTO cz_marks (cis, good_id, batch_id, load_unit_id, aggregate_code)
		SELECT $1, $2::uuid, b.id, $3::uuid, $4 FROM batches b
		WHERE b.good_id = $2::uuid AND b.production_date = '2026-09-01'`,
		boxMark["cis"], good, box, lu["cz_code"]); err != nil {
		t.Fatalf("марка короба эталона: %v", err)
	}
	if _, err := e.pool.Exec(context.Background(), `
		INSERT INTO cz_marks (cis, good_id, batch_id, cell_id, internal_warehouse_id)
		SELECT $1, $2::uuid, b.id, $3::uuid, w.id FROM batches b, internal_warehouses w
		WHERE b.good_id = $2::uuid AND b.production_date = '2026-09-02' AND w.is_default`,
		looseMark["cis"], good, looseCell); err != nil {
		t.Fatalf("марка россыпи эталона: %v", err)
	}

	code, body := e.call(t, http.MethodGet, "/api/v1/contents/snapshot", e.workerToken, "")
	if code != http.StatusOK {
		t.Fatalf("снимок: код %d, %s", code, body)
	}
	var got map[string]any
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("ответ снимка не разбирается: %v", err)
	}
	volatile := map[string]bool{"as_of": true, "created_at": true, "batch_id": true, "internal_warehouse_id": true}
	blank(want, volatile)
	blank(got, volatile)
	if !reflect.DeepEqual(got, want) {
		g, _ := json.MarshalIndent(got, "", "  ")
		t.Fatalf("снимок разошёлся с эталоном testdata/contents_snapshot.json - сверьте формат "+
			"с тем, что разбирает клиент.\nПолучено: %s", g)
	}

	// Короб ЧЗ по коду с этикетки (CZ-06): карточка той же ГЕ; кривой код - 400, не принятый - 404.
	code, body = e.call(t, http.MethodGet, "/api/v1/load-units/cz/"+lu["cz_code"].(string), e.workerToken, "")
	if code != http.StatusOK {
		t.Fatalf("короб ЧЗ по коду: код %d, %s", code, body)
	}
	var card map[string]any
	if err := json.Unmarshal(body, &card); err != nil {
		t.Fatalf("карточка короба ЧЗ не разбирается: %v", err)
	}
	if card["id"] != box || card["cz_code"] != lu["cz_code"] || card["cz_opened"] != false {
		t.Fatalf("короб ЧЗ по коду: %s", body)
	}
	if code, _ := e.call(t, http.MethodGet, "/api/v1/load-units/cz/0012", e.workerToken, ""); code != http.StatusBadRequest {
		t.Fatalf("кривой код короба ЧЗ: код %d, ждали 400", code)
	}
	if code, _ := e.call(t, http.MethodGet, "/api/v1/load-units/cz/00000000000000000001", e.workerToken, ""); code != http.StatusNotFound {
		t.Fatalf("не принятый короб ЧЗ: код %d, ждали 404", code)
	}
}

// blank заменяет значения перечисленных ключей на пустую строку по всему дереву JSON.
func blank(v any, keys map[string]bool) {
	switch x := v.(type) {
	case map[string]any:
		for k, val := range x {
			if keys[k] {
				x[k] = ""
				continue
			}
			blank(val, keys)
		}
	case []any:
		for _, val := range x {
			blank(val, keys)
		}
	}
}

// Снимок сжимается, если клиент это умеет: весь склад одним ответом.
func TestContentsHTTP_snapshotIsCompressed(t *testing.T) {
	e := newReceivingE2E(t, nil)
	req, err := http.NewRequestWithContext(context.Background(), http.MethodGet,
		e.srv.URL+"/api/v1/contents/snapshot", nil)
	if err != nil {
		t.Fatalf("запрос: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+e.workerToken)
	// Явный заголовок отключает прозрачную распаковку клиента Go - видно, что пришло по сети.
	req.Header.Set("Accept-Encoding", "gzip")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("снимок: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK || resp.Header.Get("Content-Encoding") != "gzip" {
		t.Errorf("снимок: код %d, Content-Encoding %q, ожидалось gzip",
			resp.StatusCode, resp.Header.Get("Content-Encoding"))
	}
}

// Карточка короба и содержимое ячейки: человекочитаемые строки, неживой короб, коды ошибок.
func TestContentsHTTP_cardAndCell(t *testing.T) {
	e := newReceivingE2E(t, nil)
	ctx := context.Background()
	good := uuid.NewString()
	if _, err := e.pool.Exec(ctx, `INSERT INTO goods (id,code,name,uom) VALUES ($1::uuid,'16121','Кальмар','шт')`, good); err != nil {
		t.Fatalf("товар: %v", err)
	}
	box := uuid.NewString()
	receipt := `{"operations":[{"operation_id":"` + uuid.NewString() + `","kind":"receipt_submit","payload":{"doc_number":"ТН-1","doc_date":"01-10-2026",
		"receipt_id":"` + uuid.NewString() + `","warehouse_id":"` + e.warehouse + `",
		"load_units":[{"id":"` + box + `","kind":"box"}],
		"lines":[
			{"good_id":"` + good + `","production_date":"01-09-2026","qty":12,"load_unit_id":"` + box + `"},
			{"good_id":"` + good + `","production_date":"01-09-2026","qty":3}]}}]}`
	if got := e.operations(t, receipt); len(got) != 1 || got[0] != service.StatusAccepted {
		t.Fatalf("приёмка не применилась: %v", got)
	}

	// Короб лежит в ячейке приёмки: живой, с адресом и наименованием товара.
	code, body := e.call(t, http.MethodGet, "/api/v1/load-units/"+box+"/card", e.workerToken, "")
	var card struct {
		Live        bool    `json:"live"`
		CellAddress *string `json:"cell_address"`
		Contents    []struct {
			GoodName       string `json:"good_name"`
			ProductionDate string `json:"production_date"`
			Qty            string `json:"qty"`
		} `json:"contents"`
	}
	if code != http.StatusOK || json.Unmarshal(body, &card) != nil {
		t.Fatalf("карточка: код %d, %s", code, body)
	}
	if !card.Live || card.CellAddress == nil || *card.CellAddress != "С-Н-П" || len(card.Contents) != 1 ||
		card.Contents[0].GoodName != "Кальмар" || card.Contents[0].ProductionDate != "01-09-2026" ||
		card.Contents[0].Qty != "12" {
		t.Errorf("карточка короба: %s", body)
	}

	// Ячейка приёмки: короб и россыпь 3 (15 в ячейке, 12 из них в коробе).
	code, body = e.call(t, http.MethodGet, "/api/v1/cells/"+e.cellDefault+"/contents", e.workerToken, "")
	var cell struct {
		Address   string           `json:"address"`
		LoadUnits []map[string]any `json:"load_units"`
		Loose     []struct {
			Qty string `json:"qty"`
		} `json:"loose"`
	}
	if code != http.StatusOK || json.Unmarshal(body, &cell) != nil {
		t.Fatalf("ячейка: код %d, %s", code, body)
	}
	if cell.Address != "С-Н-П" || len(cell.LoadUnits) != 1 || len(cell.Loose) != 1 || cell.Loose[0].Qty != "3" {
		t.Errorf("содержимое ячейки приёмки: %s", body)
	}

	// Пустая ячейка - пустые списки, а не null: клиенту не нужно различать.
	code, body = e.call(t, http.MethodGet, "/api/v1/cells/"+e.cell1+"/contents", e.workerToken, "")
	if code != http.StatusOK || string(body) == "" {
		t.Fatalf("пустая ячейка: код %d", code)
	}
	var empty map[string]any
	_ = json.Unmarshal(body, &empty)
	if lus, ok := empty["load_units"].([]any); !ok || len(lus) != 0 {
		t.Errorf("пустая ячейка: load_units = %v", empty["load_units"])
	}

	for _, tc := range []struct {
		path string
		want int
	}{
		{"/api/v1/load-units/" + uuid.NewString() + "/card", http.StatusNotFound},
		{"/api/v1/load-units/not-a-uuid/card", http.StatusBadRequest},
		{"/api/v1/cells/" + uuid.NewString() + "/contents", http.StatusNotFound},
		{"/api/v1/cells/not-a-uuid/contents", http.StatusBadRequest},
	} {
		if code, body := e.call(t, http.MethodGet, tc.path, e.workerToken, ""); code != tc.want {
			t.Errorf("%s: код %d, ожидалось %d (%s)", tc.path, code, tc.want, body)
		}
	}
	if code, _ := e.call(t, http.MethodGet, "/api/v1/contents/snapshot", "", ""); code != http.StatusUnauthorized {
		t.Errorf("снимок без токена: код %d, ожидалось 401", code)
	}
}

// Поиск по короткому коду и история (P5-05-1): код набран так, как на ярлыке, - с пробелом,
// строчными; история читается людьми - ФИО и адреса.
func TestContentsHTTP_searchAndHistory(t *testing.T) {
	e := newReceivingE2E(t, nil)
	good := uuid.NewString()
	if _, err := e.pool.Exec(context.Background(),
		`INSERT INTO goods (id,code,name,uom) VALUES ($1::uuid,'16121','Кальмар','шт')`, good); err != nil {
		t.Fatalf("товар: %v", err)
	}
	box := uuid.NewString()
	receipt := `{"operations":[{"operation_id":"` + uuid.NewString() + `","kind":"receipt_submit","payload":{"doc_number":"ТН-1","doc_date":"01-10-2026",
		"receipt_id":"` + uuid.NewString() + `","warehouse_id":"` + e.warehouse + `","supplier_id":"` + e.supplier + `",
		"load_units":[{"id":"` + box + `","kind":"box"}],
		"lines":[{"good_id":"` + good + `","production_date":"01-09-2026","qty":12,"load_unit_id":"` + box + `"}]}}]}`
	if got := e.operations(t, receipt); len(got) != 1 || got[0] != service.StatusAccepted {
		t.Fatalf("приёмка не применилась: %v", got)
	}

	hex := strings.ReplaceAll(box, "-", "")
	typed := strings.ToLower(hex[24:28] + " " + hex[28:]) // «9fa0 b1c2» - как на ярлыке
	code, body := e.call(t, http.MethodGet, "/api/v1/load-units?code="+url.QueryEscape(typed), e.workerToken, "")
	var found []struct {
		ID          string  `json:"id"`
		Live        bool    `json:"live"`
		CellAddress *string `json:"cell_address"`
	}
	if code != http.StatusOK || json.Unmarshal(body, &found) != nil {
		t.Fatalf("поиск: код %d, %s", code, body)
	}
	if len(found) != 1 || found[0].ID != box || !found[0].Live || found[0].CellAddress == nil {
		t.Errorf("поиск по коду %q: %s", typed, body)
	}

	// Ничего не найдено - пустой список, а не null.
	code, body = e.call(t, http.MethodGet, "/api/v1/load-units?code=00000000", e.workerToken, "")
	if code != http.StatusOK || strings.TrimSpace(string(body)) != "[]" {
		t.Errorf("пустой поиск: код %d, %s", code, body)
	}

	code, body = e.call(t, http.MethodGet, "/api/v1/load-units/"+box+"/history", e.workerToken, "")
	var hist struct {
		Receipt *struct {
			DocNumber  string  `json:"doc_number"`
			DocDate    string  `json:"doc_date"`
			ReceivedBy string  `json:"received_by"`
			Supplier   *string `json:"supplier"`
			PostedAt   *string `json:"posted_at"`
		} `json:"receipt"`
		Moves []struct {
			From   *string `json:"from"`
			To     string  `json:"to"`
			Source string  `json:"source"`
		} `json:"moves"`
	}
	if code != http.StatusOK || json.Unmarshal(body, &hist) != nil {
		t.Fatalf("история: код %d, %s", code, body)
	}
	if hist.Receipt == nil || hist.Receipt.ReceivedBy != "Кладовщик" || hist.Receipt.Supplier == nil ||
		hist.Receipt.DocNumber != "ТН-1" || hist.Receipt.DocDate != "01-10-2026" ||
		*hist.Receipt.Supplier != "ООО «Голсера»" || hist.Receipt.PostedAt == nil {
		t.Errorf("приёмка в истории: %s", body)
	}
	if len(hist.Moves) != 1 || hist.Moves[0].From != nil || hist.Moves[0].To != "С-Н-П" || hist.Moves[0].Source != "receipt" {
		t.Errorf("переносы в истории: %s", body)
	}

	for _, tc := range []struct {
		path string
		want int
	}{
		{"/api/v1/load-units?code=", http.StatusBadRequest},
		{"/api/v1/load-units?code=XYZ", http.StatusBadRequest},
		{"/api/v1/load-units?code=123456789", http.StatusBadRequest},
		{"/api/v1/load-units/" + uuid.NewString() + "/history", http.StatusNotFound},
		{"/api/v1/load-units/not-a-uuid/history", http.StatusBadRequest},
	} {
		if code, body := e.call(t, http.MethodGet, tc.path, e.workerToken, ""); code != tc.want {
			t.Errorf("%s: код %d, ожидалось %d (%s)", tc.path, code, tc.want, body)
		}
	}
}

// Снимок склада - и странице портала «Остатки склада» (ADHOC-56): должность только с
// «Остатки склада: смотреть» снимок получает, а содержимое ячейки (только ТСД) - нет.
func TestContentsHTTP_snapshotForPortalStock(t *testing.T) {
	e := newReceivingE2E(t, nil)
	ctx := context.Background()
	var user string
	if err := e.pool.QueryRow(ctx, `WITH p AS (
			INSERT INTO positions (name, rights) VALUES ('Офис', ARRAY['portal.stock.view']) RETURNING id)
		INSERT INTO users (login,password_hash,full_name,position_id)
		SELECT '90000043','x','Офис',id FROM p RETURNING id::text`).Scan(&user); err != nil {
		t.Fatalf("пользователь портала: %v", err)
	}
	token, err := auth.NewTokenManager("test-secret", time.Hour, 24*time.Hour).
		IssueAccess(user, string(model.RoleEmployee))
	if err != nil {
		t.Fatal(err)
	}
	if code, body := e.call(t, http.MethodGet, "/api/v1/contents/snapshot", token, ""); code != http.StatusOK {
		t.Errorf("снимок с правом портала: код %d (%s)", code, body)
	}
	if code, _ := e.call(t, http.MethodGet, "/api/v1/cells/"+uuid.NewString()+"/contents", token, ""); code != http.StatusForbidden {
		t.Errorf("ячейка с правом портала: код %d, ожидалось 403", code)
	}
}
