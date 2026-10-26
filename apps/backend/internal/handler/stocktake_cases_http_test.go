package handler_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/xuri/excelize/v2"
)

// P10-06D: сценарные тесты пересчёта через настоящий роутер — так, как его проходят склад и
// офис: старший смены заводит, кладовщик считает ячейку очередью ТСД, офис закрывает пересчёт,
// забирает «Инвентаризацию» и решает проблемы «не найдено».

// stocktakeEnv — стенд сценариев пересчёта: склад приёмки плюс вторая ячейка и два товара.
type stocktakeEnv struct {
	*rcvEnv
	cell2         string
	lemon, snack  string // товары
	lemonBatch    string // партия 01-01-2026
	snackBatch    string // партия 01-02-2026
	mainWarehouse string // внутренний склад «Основной»
}

func newStocktakeEnv(t *testing.T) *stocktakeEnv {
	t.Helper()
	e := &stocktakeEnv{rcvEnv: newReceivingE2E(t, nil)}
	e.cell2 = e.scalar(t, `INSERT INTO cells (warehouse_id, address) VALUES ($1::uuid, 'M1-1-1-2') RETURNING id::text`,
		e.warehouse)
	e.lemon = e.scalar(t, `INSERT INTO goods (code, name, uom) VALUES ('L-1', 'Лимонад', 'шт') RETURNING id::text`)
	e.snack = e.scalar(t, `INSERT INTO goods (code, name, uom) VALUES ('S-1', 'Снек', 'шт') RETURNING id::text`)
	e.lemonBatch = e.scalar(t, `INSERT INTO batches (good_id, production_date) VALUES ($1::uuid, '2026-01-01')
		RETURNING id::text`, e.lemon)
	e.snackBatch = e.scalar(t, `INSERT INTO batches (good_id, production_date) VALUES ($1::uuid, '2026-02-01')
		RETURNING id::text`, e.snack)
	e.mainWarehouse = e.scalar(t, `SELECT id::text FROM internal_warehouses WHERE is_default`)
	return e
}

// put кладёт остаток россыпью на «Основной».
func (e *stocktakeEnv) put(t *testing.T, cell, good, batch string, qty int) {
	t.Helper()
	if _, err := e.pool.Exec(t.Context(), `INSERT INTO stock (cell_id, good_id, batch_id, internal_warehouse_id, qty)
		VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, $5)
		ON CONFLICT (cell_id, good_id, batch_id, internal_warehouse_id) DO UPDATE SET qty = stock.qty + EXCLUDED.qty`,
		cell, good, batch, e.mainWarehouse, qty); err != nil {
		t.Fatalf("остаток: %v", err)
	}
}

// box ставит в ячейку короб с товаром: состав короба входит в остаток ячейки, как после
// размещения.
func (e *stocktakeEnv) box(t *testing.T, cell, good, batch string, qty int) string {
	t.Helper()
	id := e.scalar(t, `INSERT INTO load_units (id, kind, cell_id, status) VALUES ($1::uuid, 'box', $2::uuid, 'placed')
		RETURNING id::text`, uuid.NewString(), cell)
	if _, err := e.pool.Exec(t.Context(), `INSERT INTO lu_content (load_unit_id, good_id, batch_id, qty)
		VALUES ($1::uuid, $2::uuid, $3::uuid, $4)`, id, good, batch, qty); err != nil {
		t.Fatalf("состав короба: %v", err)
	}
	e.put(t, cell, good, batch, qty)
	return id
}

// create заводит пересчёт от имени старшего смены и возвращает его id и ячейки по адресу.
func (e *stocktakeEnv) create(t *testing.T, body string) (string, map[string]string) {
	t.Helper()
	code, raw := e.call(t, http.MethodPost, "/api/v1/stocktakes", e.adminToken, body)
	if code != http.StatusCreated {
		t.Fatalf("завести пересчёт: код %d, %s", code, raw)
	}
	var st struct {
		ID string `json:"id"`
	}
	mustJSON(t, raw, &st)
	_, raw = e.call(t, http.MethodGet, "/api/v1/stocktakes/"+st.ID+"/cells", e.workerToken, "")
	var cells struct {
		Cells []struct {
			ID      string `json:"id"`
			Address string `json:"address"`
		} `json:"cells"`
	}
	mustJSON(t, raw, &cells)
	byAddress := map[string]string{}
	for _, c := range cells.Cells {
		byAddress[c.Address] = c.ID
	}
	return st.ID, byAddress
}

// start — кладовщик берёт ячейку и сканирует её на месте: снимок «ожидалось».
func (e *stocktakeEnv) start(t *testing.T, stCell string) {
	t.Helper()
	if code, raw := e.call(t, http.MethodPost, "/api/v1/stocktake-cells/"+stCell+"/take", e.workerToken, ""); code != http.StatusNoContent {
		t.Fatalf("взять ячейку: код %d, %s", code, raw)
	}
	e.rescan(t, stCell)
}

// rescan — повторный скан ячейки: сбитый подсчёт начинается заново со свежим снимком.
func (e *stocktakeEnv) rescan(t *testing.T, stCell string) {
	t.Helper()
	if code, raw := e.call(t, http.MethodPost, "/api/v1/stocktake-cells/"+stCell+"/start", e.workerToken, ""); code != http.StatusOK {
		t.Fatalf("скан ячейки: код %d, %s", code, raw)
	}
}

// submit отправляет факт ячейки операцией очереди, как ТСД; возвращает статус и текст отказа.
func (e *stocktakeEnv) submit(t *testing.T, stCell, loose, boxes string) (string, string) {
	t.Helper()
	return e.operation(t, `{"operations":[{"operation_id":"`+uuid.NewString()+`","kind":"stocktake_cell_submit",
		"payload":{"stocktake_cell_id":"`+stCell+`","loose":[`+loose+`],"boxes":[`+boxes+`]}}]}`)
}

// operation отправляет батч из одной операции и возвращает её статус и текст отказа — тот,
// что ТСД покажет кладовщику дословно.
func (e *stocktakeEnv) operation(t *testing.T, batch string) (string, string) {
	t.Helper()
	code, raw := e.call(t, http.MethodPost, "/api/v1/operations", e.workerToken, batch)
	var body struct {
		Results []struct {
			Status string `json:"status"`
			Error  string `json:"error"`
		} `json:"results"`
	}
	if code != http.StatusOK || json.Unmarshal(raw, &body) != nil || len(body.Results) != 1 {
		t.Fatalf("батч: код %d, %s", code, raw)
	}
	return body.Results[0].Status, body.Results[0].Error
}

// qty — остаток товара в ячейке целым числом, сложенный по партиям и внутренним складам.
func (e *stocktakeEnv) qty(t *testing.T, cell, good string) string {
	t.Helper()
	return e.scalar(t, `SELECT COALESCE(sum(qty), 0)::int::text FROM stock WHERE cell_id = $1::uuid AND good_id = $2::uuid`,
		cell, good)
}

// cellStatus — состояние ячейки пересчёта.
func (e *stocktakeEnv) cellStatus(t *testing.T, stCell string) string {
	t.Helper()
	return e.scalar(t, `SELECT status FROM stocktake_cells WHERE id = $1::uuid`, stCell)
}

// close закрывает пересчёт от имени офиса; force — досрочно.
func (e *stocktakeEnv) close(t *testing.T, id string, force bool) (int, string) {
	t.Helper()
	body := ""
	if force {
		body = `{"force":true}`
	}
	code, raw := e.call(t, http.MethodPost, "/api/v1/stocktakes/"+id+"/close", e.adminToken, body)
	return code, strings.TrimSpace(string(raw))
}

// inventory скачивает единственный документ «Инвентаризация» и возвращает строки листа под
// шапкой таблицы: «Ячейка | Код | … | Ожидалось | Факт | Расхождение | Пометка».
func (e *stocktakeEnv) inventory(t *testing.T, sheet string) []string {
	t.Helper()
	_, raw := e.call(t, http.MethodGet, "/api/v1/documents?kind=stocktake", e.adminToken, "")
	var docs []struct {
		ID string `json:"id"`
	}
	mustJSON(t, raw, &docs)
	if len(docs) != 1 {
		t.Fatalf("документы «Инвентаризация»: %s", raw)
	}
	code, file := e.call(t, http.MethodGet, "/api/v1/documents/"+docs[0].ID+"/file.xlsx", e.adminToken, "")
	if code != http.StatusOK {
		t.Fatalf("файл «Инвентаризации»: код %d", code)
	}
	f, err := excelize.OpenReader(bytes.NewReader(file))
	if err != nil {
		t.Fatalf("открыть xlsx: %v", err)
	}
	defer func() { _ = f.Close() }()
	all, err := f.GetRows(sheet)
	if err != nil {
		t.Fatalf("лист %q: %v", sheet, err)
	}
	var out []string
	inTable := false
	for _, r := range all {
		if len(r) > 0 && r[0] == "Ячейка" {
			inTable = true
			continue
		}
		if inTable {
			out = append(out, strings.Join(r, " | "))
		}
	}
	return out
}

// Недостача, излишек и «не найдено» — от заведения до решения офиса. В M1-1-1-1 лежат 10
// лимонада россыпью и короб с 6, в M1-1-1-2 — 2 снека. Кладовщик насчитал 7 лимонада, короб
// не нашёл; снеков — 5 и ещё 4 лимонада сверх учёта. Остаток приводится к факту сразу по
// ячейке, короб уходит на склад «Не найдено» проблемой, документ показывает расхождения, а
// «нашлось» офиса возвращает короб на «Основной».
func TestStocktakeHTTP_shortageSurplusNotFound(t *testing.T) {
	e := newStocktakeEnv(t)
	e.put(t, e.cell1, e.lemon, e.lemonBatch, 10)
	lu := e.box(t, e.cell1, e.lemon, e.lemonBatch, 6)
	e.put(t, e.cell2, e.snack, e.snackBatch, 2)

	id, cells := e.create(t, `{"warehouse_id":"`+e.warehouse+`","scope_kind":"cells","object_ids":["`+
		e.cell1+`","`+e.cell2+`"]}`)
	c1, c2 := cells["M1-1-1-1"], cells["M1-1-1-2"]
	if c1 == "" || c2 == "" || len(cells) != 2 {
		t.Fatalf("ячейки пересчёта: %v", cells)
	}

	e.start(t, c1)
	if status, msg := e.submit(t, c1, `{"good_id":"`+e.lemon+`","production_date":"01-01-2026","qty":7}`, ``); status != "accepted" {
		t.Fatalf("подсчёт M1-1-1-1: %s %s", status, msg)
	}
	if got := e.byWarehouse(t, e.cell1); got != "MAIN:7.000 NOT_FOUND:6.000" {
		t.Errorf("остаток M1-1-1-1 после подсчёта: %q — ожидались 7 на «Основном» и короб на «Не найдено»", got)
	}
	if got := e.scalar(t, `SELECT w.code FROM load_units l JOIN internal_warehouses w ON w.id = l.internal_warehouse_id
		WHERE l.id = $1::uuid`, lu); got != "NOT_FOUND" {
		t.Errorf("короб на складе %s, ожидался NOT_FOUND", got)
	}
	_, raw := e.call(t, http.MethodGet, "/api/v1/problems/current", e.workerToken, "")
	var problems []struct {
		ID     string `json:"id"`
		Reason string `json:"reason"`
	}
	mustJSON(t, raw, &problems)
	if len(problems) != 1 || problems[0].Reason != "not_found" {
		t.Fatalf("проблемы склада после подсчёта: %s", raw)
	}

	e.start(t, c2)
	if status, msg := e.submit(t, c2, `{"good_id":"`+e.snack+`","production_date":"01-02-2026","qty":5},
		{"good_id":"`+e.lemon+`","production_date":"01-01-2026","qty":4}`, ``); status != "accepted" {
		t.Fatalf("подсчёт M1-1-1-2: %s %s", status, msg)
	}
	if got := e.qty(t, e.cell2, e.snack) + " / " + e.qty(t, e.cell2, e.lemon); got != "5 / 4" {
		t.Errorf("остаток M1-1-1-2 (снек / лимонад): %s, ожидалось 5 / 4", got)
	}
	if got := e.scalar(t, `SELECT count(*)::text FROM audit_log WHERE action = 'stocktake.adjust'`); got != "3" {
		t.Errorf("правок остатка в журнале: %s, ожидалось 3 (лимонад M1-1-1-1, снек и лимонад M1-1-1-2)", got)
	}

	if code, body := e.close(t, id, false); code != http.StatusOK || body != `{"uncounted":0}` {
		t.Fatalf("закрыть пересчёт: код %d, %s", code, body)
	}
	want := []string{
		// Короб развёрнут в состав и сложен с россыпью той же позиции: 10 + 6 ожидалось, 7 найдено.
		"M1-1-1-1 | L-1 | Лимонад | 01.01.2026 | Основной | 16 | 7 | -9 | не найдено — проблема склада",
		"M1-1-1-2 | L-1 | Лимонад | 01.01.2026 | Основной | 0 | 4 | 4",
		"M1-1-1-2 | S-1 | Снек | 01.02.2026 | Основной | 2 | 5 | 3",
	}
	if got := e.inventory(t, "Расхождения"); strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("лист «Расхождения»:\n%s\nожидалось:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}

	// Короб нашёлся: офис проводит «нашлось» — товар возвращается на «Основной» той же ячейки.
	if code, raw := e.call(t, http.MethodPost, "/api/v1/problems/"+problems[0].ID+"/resolve", e.adminToken,
		`{"decision":"place"}`); code != http.StatusNoContent {
		t.Fatalf("решение «нашлось»: код %d, %s", code, raw)
	}
	if got := e.byWarehouse(t, e.cell1); got != "MAIN:13.000" {
		t.Errorf("остаток M1-1-1-1 после «нашлось»: %q, ожидалось MAIN:13", got)
	}
}

// Движение во время пересчёта: пока M1-1-1-1 считают, другой кладовщик переносит из неё 2
// лимонада в M1-1-1-2. Сервер движение принимает и сбивает подсчёт, факт по старому снимку
// получает отказ с понятным текстом, остаток не трогается; после повторного скана ячейки
// снимок свежий, и факт по нему проходит.
func TestStocktakeHTTP_movementDuringCount(t *testing.T) {
	e := newStocktakeEnv(t)
	e.put(t, e.cell1, e.lemon, e.lemonBatch, 10)

	_, cells := e.create(t, `{"warehouse_id":"`+e.warehouse+`","scope_kind":"cells","object_ids":["`+e.cell1+`"]}`)
	c1 := cells["M1-1-1-1"]
	e.start(t, c1)

	status, msg := e.operation(t, `{"operations":[{"operation_id":"`+uuid.NewString()+`","kind":"movement_submit",
		"payload":{"movement_id":"`+uuid.NewString()+`","movement_kind":"move","warehouse_id":"`+e.warehouse+`",
		"lines":[{"good_id":"`+e.lemon+`","production_date":"01-01-2026","qty":2,
		"from_cell_id":"`+e.cell1+`","to_cell_id":"`+e.cell2+`"}]}}]}`)
	if status != "accepted" {
		t.Fatalf("перемещение во время пересчёта: %s %s", status, msg)
	}
	if got := e.cellStatus(t, c1); got != "disrupted" {
		t.Fatalf("ячейка после движения: %s, ожидалось disrupted", got)
	}

	status, msg = e.submit(t, c1, `{"good_id":"`+e.lemon+`","production_date":"01-01-2026","qty":10}`, ``)
	if status != "rejected" || msg != "пока ячейку считали, через неё прошло движение — посчитайте ячейку заново" {
		t.Errorf("факт по сбитому подсчёту: %s %q — ожидался отказ с просьбой посчитать заново", status, msg)
	}
	if got := e.qty(t, e.cell1, e.lemon); got != "8" {
		t.Errorf("остаток после отказа: %s, ожидалось 8 (10 − перемещённые 2)", got)
	}

	e.rescan(t, c1)
	if got := e.scalar(t, `SELECT expected_qty::int::text FROM stocktake_lines WHERE stocktake_cell_id = $1::uuid`, c1); got != "8" {
		t.Errorf("свежий снимок: ожидалось %s, должно быть 8", got)
	}
	if status, msg := e.submit(t, c1, `{"good_id":"`+e.lemon+`","production_date":"01-01-2026","qty":7}`, ``); status != "accepted" {
		t.Fatalf("факт после повторного скана: %s %s", status, msg)
	}
	if got := e.qty(t, e.cell1, e.lemon) + " / " + e.qty(t, e.cell2, e.lemon); got != "7 / 2" {
		t.Errorf("остаток (M1-1-1-1 / M1-1-1-2): %s, ожидалось 7 / 2", got)
	}
	if got := e.cellStatus(t, c1); got != "counted" {
		t.Errorf("ячейка после факта: %s, ожидалось counted", got)
	}
}

// Досрочное закрытие: из двух ячеек посчитана одна. Без подтверждения пересчёт не
// закрывается; с подтверждением непосчитанная ячейка остаток не трогает, а в документе стоит
// строкой «не считалась».
func TestStocktakeHTTP_earlyClose(t *testing.T) {
	e := newStocktakeEnv(t)
	e.put(t, e.cell1, e.lemon, e.lemonBatch, 10)
	e.put(t, e.cell2, e.snack, e.snackBatch, 2)

	id, cells := e.create(t, `{"warehouse_id":"`+e.warehouse+`","scope_kind":"cells","object_ids":["`+
		e.cell1+`","`+e.cell2+`"]}`)
	c1 := cells["M1-1-1-1"]
	e.start(t, c1)
	if status, msg := e.submit(t, c1, `{"good_id":"`+e.lemon+`","production_date":"01-01-2026","qty":10}`, ``); status != "accepted" {
		t.Fatalf("подсчёт M1-1-1-1: %s %s", status, msg)
	}

	if code, body := e.close(t, id, false); code != http.StatusConflict {
		t.Errorf("закрыть без подтверждения: код %d, %s — ожидался 409", code, body)
	}
	if code, body := e.close(t, id, true); code != http.StatusOK || body != `{"uncounted":1}` {
		t.Fatalf("закрыть досрочно: код %d, %s", code, body)
	}
	if got := e.qty(t, e.cell2, e.snack); got != "2" {
		t.Errorf("остаток непосчитанной ячейки: %s, ожидалось 2", got)
	}
	want := []string{
		"M1-1-1-1 | L-1 | Лимонад | 01.01.2026 | Основной | 10 | 10 | 0",
		"M1-1-1-2 |  |  |  |  |  |  |  | не считалась",
	}
	if got := e.inventory(t, "Инвентаризация"); strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("лист «Инвентаризация»:\n%s\nожидалось:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	// Закрытый пересчёт новых подсчётов не принимает.
	if code, _ := e.call(t, http.MethodPost, "/api/v1/stocktake-cells/"+cells["M1-1-1-2"]+"/take", e.workerToken, ""); code == http.StatusNoContent {
		t.Errorf("ячейку закрытого пересчёта удалось взять")
	}
}

// ADHOC-48: ТСД перед движением спрашивает, идёт ли в ячейке подсчёт. Взятая и не начатая —
// нет (снимка ещё нет, сбивать нечего); после скана — да, с номером пересчёта и тем, кто
// считает; после факта — снова нет. Соседняя ячейка и неверный id — нет.
func TestStocktakeHTTP_cellCounting(t *testing.T) {
	e := newStocktakeEnv(t)
	e.put(t, e.cell1, e.lemon, e.lemonBatch, 10)
	_, cells := e.create(t, `{"warehouse_id":"`+e.warehouse+`","scope_kind":"cells","object_ids":["`+e.cell1+`"]}`)
	c1 := cells["M1-1-1-1"]
	counting := func(cell string) string {
		t.Helper()
		code, raw := e.call(t, http.MethodGet, "/api/v1/cells/"+cell+"/stocktake-count", e.workerToken, "")
		if code != http.StatusOK {
			t.Fatalf("подсчёт в ячейке: код %d, %s", code, raw)
		}
		var body struct {
			Counting *struct {
				StocktakeNumber int64  `json:"stocktake_number"`
				Address         string `json:"address"`
				CountedBy       string `json:"counted_by"`
				StartedAt       string `json:"started_at"`
			} `json:"counting"`
		}
		mustJSON(t, raw, &body)
		if body.Counting == nil {
			return "нет"
		}
		if body.Counting.StocktakeNumber == 0 || body.Counting.StartedAt == "" {
			t.Errorf("подсчёт без номера или времени: %s", raw)
		}
		return body.Counting.Address + " · " + body.Counting.CountedBy
	}

	if code, raw := e.call(t, http.MethodPost, "/api/v1/stocktake-cells/"+c1+"/take", e.workerToken, ""); code != http.StatusNoContent {
		t.Fatalf("взять ячейку: код %d, %s", code, raw)
	}
	if got := counting(e.cell1); got != "нет" {
		t.Errorf("взятая, не начатая ячейка: %s, ожидалось «нет»", got)
	}
	e.rescan(t, c1)
	if got := counting(e.cell1); got != "M1-1-1-1 · Кладовщик" {
		t.Errorf("ячейка на подсчёте: %s", got)
	}
	if got := counting(e.cell2); got != "нет" {
		t.Errorf("соседняя ячейка: %s, ожидалось «нет»", got)
	}
	if got := counting("не-uuid"); got != "нет" {
		t.Errorf("неверный id: %s, ожидалось «нет»", got)
	}
	if status, msg := e.submit(t, c1, `{"good_id":"`+e.lemon+`","production_date":"01-01-2026","qty":10}`, ``); status != "accepted" {
		t.Fatalf("подсчёт: %s %s", status, msg)
	}
	if got := counting(e.cell1); got != "нет" {
		t.Errorf("посчитанная ячейка: %s, ожидалось «нет»", got)
	}
}
