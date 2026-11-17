package handler_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"

	"craftwms/internal/importer"
)

// ADHOC-57: страница «Ячейки» через настоящий роутер. Смотреть и выгружать - с правом раздела
// «Ячейки», менять галочки - с правом «Ячейки: изменять настройки»; кладовщику без них - 403.
func TestCellSetupHTTP(t *testing.T) {
	e := newReceivingE2E(t, nil)

	for _, c := range []struct{ method, path, body string }{
		{http.MethodGet, "/api/v1/cells/setup", ""},
		{http.MethodGet, "/api/v1/cells/export.xlsx", ""},
		{http.MethodPatch, "/api/v1/cells/setup", `{"cell_ids":["` + e.cell1 + `"],"label_small":true}`},
	} {
		if code, _ := e.call(t, c.method, c.path, e.workerToken, c.body); code != http.StatusForbidden {
			t.Errorf("кладовщик %s %s: %d, ждали 403", c.method, c.path, code)
		}
	}

	// Список: ячейка приёмки не показывается, у M1-1-1-1 - умолчания.
	code, body := e.call(t, http.MethodGet, "/api/v1/cells/setup?warehouse=SHB", e.adminToken, "")
	var setup struct {
		Warehouse string `json:"warehouse"`
		Cells     []struct {
			ID         string  `json:"id"`
			Address    string  `json:"address"`
			RackCode   *string `json:"rack_code"`
			LabelSmall bool    `json:"label_small"`
		} `json:"cells"`
		Racks []json.RawMessage `json:"racks"`
	}
	if code != http.StatusOK || json.Unmarshal(body, &setup) != nil || len(setup.Cells) != 1 ||
		setup.Cells[0].Address != "M1-1-1-1" || setup.Cells[0].RackCode != nil || setup.Cells[0].LabelSmall {
		t.Fatalf("список: %d %s", code, body)
	}

	code, body = e.call(t, http.MethodPatch, "/api/v1/cells/setup", e.adminToken,
		`{"cell_ids":["`+e.cell1+`"],"label_small":true,"side_card":true}`)
	if code != http.StatusOK || string(bytes.TrimSpace(body)) != `{"cells_updated":1}` {
		t.Errorf("правка: %d %s", code, body)
	}
	for _, c := range []struct {
		body string
		want int
	}{
		{`{"cell_ids":[],"label_small":true}`, http.StatusBadRequest},
		{`{"cell_ids":["` + e.cell1 + `"]}`, http.StatusBadRequest},
		{`{"cell_ids":["` + e.cellDefault + `"],"is_floor":true}`, http.StatusConflict},
		{`не json`, http.StatusBadRequest},
	} {
		if code, body := e.call(t, http.MethodPatch, "/api/v1/cells/setup", e.adminToken, c.body); code != c.want {
			t.Errorf("%s: %d %s, ждали %d", c.body, code, body, c.want)
		}
	}
	if code, _ := e.call(t, http.MethodGet, "/api/v1/cells/setup?warehouse=NOPE", e.adminToken, ""); code != http.StatusNotFound {
		t.Errorf("неизвестный склад: %d", code)
	}

	// Выгрузка - файл формата rack_labels с изменённой галочкой.
	code, body = e.call(t, http.MethodGet, "/api/v1/cells/export.xlsx", e.adminToken, "")
	if code != http.StatusOK {
		t.Fatalf("выгрузка: %d %s", code, body)
	}
	parsed, err := importer.ParseCells(bytes.NewReader(body))
	if err != nil || len(parsed.Cells) != 1 || !parsed.Cells[0].LabelSmall {
		t.Errorf("разбор выгрузки: %v %+v", err, parsed)
	}
}

// ADHOC-57: печать - POST с видом и выборкой; кладовщику без права «печатать» - 403.
func TestCellLabelsHTTP(t *testing.T) {
	e := newReceivingE2E(t, nil)
	const path = "/api/v1/cells/labels.pdf?warehouse=SHB"
	if code, _ := e.call(t, http.MethodPost, path, e.workerToken, `{"kind":"large"}`); code != http.StatusForbidden {
		t.Errorf("кладовщик: %d, ждали 403", code)
	}
	code, body := e.call(t, http.MethodPost, path, e.adminToken, `{"kind":"large","cell_ids":["`+e.cell1+`"]}`)
	if code != http.StatusOK || !bytes.HasPrefix(body, []byte("%PDF")) {
		t.Fatalf("печать: %d %.200s", code, body)
	}
	for _, c := range []struct {
		body string
		want int
	}{
		{`{"kind":"huge"}`, http.StatusBadRequest},
		{`не json`, http.StatusBadRequest},
		{`{"kind":"large","cell_ids":["` + e.cellDefault + `"]}`, http.StatusConflict},
		{`{"kind":"small"}`, http.StatusUnprocessableEntity}, // малых ячеек на складе нет
		{`{"kind":"cards"}`, http.StatusUnprocessableEntity}, // и стеллажей с карточкой
	} {
		if code, body := e.call(t, http.MethodPost, path, e.adminToken, c.body); code != c.want {
			t.Errorf("%s: %d %s, ждали %d", c.body, code, body, c.want)
		}
	}
	if code, _ := e.call(t, http.MethodGet, path, e.adminToken, ""); code != http.StatusMethodNotAllowed {
		t.Errorf("прежний GET: %d, ждали 405", code)
	}
}
