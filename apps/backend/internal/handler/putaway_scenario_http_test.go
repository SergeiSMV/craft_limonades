package handler_test

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/xuri/excelize/v2"

	"craftwms/internal/auth"
	"craftwms/internal/model"
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
	receipt := `{"operations":[{"operation_id":"` + uuid.NewString() + `","kind":"receipt_submit","payload":{"doc_number":"ТН-1","doc_date":"01-10-2026",
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

// Сценарные тесты размещения (P5-06D): весь путь через настоящий роутер — приёмка рождает
// задание, кладовщик разносит его сеансами с ТСД, оператор получает «Движение» в портале.
// Итог каждого шага проверяется там, где его увидят люди: остаток по ячейкам, задание в
// разделе «Задания», снимок содержимого склада на терминале, документ и сам .xlsx.

// putawayEnv — окружение приёмки плюс вторая ячейка хранения, товар и второй кладовщик.
type putawayEnv struct {
	*rcvEnv
	cell2        string
	good         string
	worker2Token string
}

// newPutawayE2E собирает окружение сценариев размещения.
func newPutawayE2E(t *testing.T) *putawayEnv {
	t.Helper()
	e := &putawayEnv{rcvEnv: newReceivingE2E(t, nil)}
	ctx := context.Background()
	if err := e.pool.QueryRow(ctx, `INSERT INTO cells (warehouse_id,address) VALUES ($1::uuid,'M1-1-1-2')
		RETURNING id::text`, e.warehouse).Scan(&e.cell2); err != nil {
		t.Fatalf("ячейка M1-1-1-2: %v", err)
	}
	if err := e.pool.QueryRow(ctx, `INSERT INTO goods (code,name,uom) VALUES ('16121','Кальмар','шт')
		RETURNING id::text`).Scan(&e.good); err != nil {
		t.Fatalf("товар: %v", err)
	}
	var worker2 string
	if err := e.pool.QueryRow(ctx, `INSERT INTO users (login,password_hash,full_name,position_id)
		VALUES ('90000043','x','Сменщик','7a000000-0000-4000-8000-000000000002') RETURNING id::text`).Scan(&worker2); err != nil {
		t.Fatalf("второй кладовщик: %v", err)
	}
	// Тот же секрет, что у роутера окружения: токен проверяется им.
	tokens := auth.NewTokenManager("test-secret", time.Hour, 24*time.Hour)
	var err error
	if e.worker2Token, err = tokens.IssueAccess(worker2, string(model.RoleEmployee)); err != nil {
		t.Fatalf("токен второго кладовщика: %v", err)
	}
	return e
}

// receive проводит приёмку от поставщика с накладной: два короба по 12 (партия 01.09) и 5
// россыпью (партия 02.09) в ячейку приёмки. Возвращает короба и задание, которое из неё родилось.
func (e *putawayEnv) receive(t *testing.T) (box1, box2 string, task taskView) {
	t.Helper()
	box1, box2 = uuid.NewString(), uuid.NewString()
	got := e.operations(t, jsonf(`{"operations":[{"operation_id":%q,"kind":"receipt_submit","payload":{
		"receipt_id":%q,"warehouse_id":%q,"supplier_id":%q,"doc_number":"ТН-77","doc_date":"01-10-2026",
		"load_units":[{"id":%q,"kind":"box"},{"id":%q,"kind":"box"}],
		"lines":[
			{"good_id":%q,"production_date":"01-09-2026","qty":12,"load_unit_id":%q},
			{"good_id":%q,"production_date":"01-09-2026","qty":12,"load_unit_id":%q},
			{"good_id":%q,"production_date":"02-09-2026","qty":5}]}}]}`,
		uuid.NewString(), uuid.NewString(), e.warehouse, e.supplier, box1, box2,
		e.good, box1, e.good, box2, e.good))
	if strings.Join(got, ",") != service.StatusAccepted {
		t.Fatalf("приёмка: %v", got)
	}
	tasks := e.tasks(t, e.workerToken)
	if len(tasks) != 1 {
		t.Fatalf("заданий после приёмки: %d", len(tasks))
	}
	return box1, box2, tasks[0]
}

// taskView — задание глазами раздела «Задания» на ТСД.
type taskView struct {
	ID           string `json:"id"`
	Number       int64  `json:"number"`
	Status       string `json:"status"`
	AssigneeName string `json:"assignee_name"`
	Items        []struct {
		LoadUnitID *string `json:"load_unit_id"`
		Remaining  *string `json:"remaining"`
		Placed     bool    `json:"placed"`
	} `json:"items"`
}

// tasks — текущие задания так, как их видит кладовщик с этим токеном.
func (e *putawayEnv) tasks(t *testing.T, token string) []taskView {
	t.Helper()
	code, raw := e.call(t, http.MethodGet, "/api/v1/tasks", token, "")
	var out []taskView
	if code != http.StatusOK || json.Unmarshal(raw, &out) != nil {
		t.Fatalf("GET /tasks: %d %s", code, raw)
	}
	return out
}

// putaway — тело операции сеанса размещения: короба и россыпь партии 02.09.
func (e *putawayEnv) putaway(taskID, putawayID string, lines ...string) string {
	return jsonf(`{"operations":[{"operation_id":%q,"kind":"putaway_submit","payload":{
		"putaway_id":%q,"task_id":%q,"warehouse_id":%q,"lines":[%s]}}]}`,
		uuid.NewString(), putawayID, taskID, e.warehouse, strings.Join(lines, ","))
}

func boxLine(box, cell string) string {
	return jsonf(`{"load_unit_id":%q,"to_cell_id":%q}`, box, cell)
}

func (e *putawayEnv) looseLine(qty int, cell string) string {
	return jsonf(`{"good_id":%q,"production_date":"02-09-2026","qty":%d,"to_cell_id":%q}`, e.good, qty, cell)
}

// stock — остаток товара по ячейкам приёмки, M1-1-1-1 и M1-1-1-2.
func (e *putawayEnv) stock(t *testing.T) string {
	t.Helper()
	return e.qtyIn(t, e.cellDefault, e.good) + " / " + e.qtyIn(t, e.cell1, e.good) + " / " + e.qtyIn(t, e.cell2, e.good)
}

// movementDocs — документы «Движение» глазами портала.
func (e *rcvEnv) movementDocs(t *testing.T) []map[string]any {
	t.Helper()
	code, raw := e.call(t, http.MethodGet, "/api/v1/documents?kind="+model.ReportKindMovement, e.adminToken, "")
	var out []map[string]any
	if code != http.StatusOK || json.Unmarshal(raw, &out) != nil {
		t.Fatalf("список «Движения»: %d %s", code, raw)
	}
	return out
}

// movementXLSX скачивает «Движение» из портала: шапка и строки таблицы под ней.
func (e *rcvEnv) movementXLSX(t *testing.T, docID string) (map[string]string, [][]string) {
	t.Helper()
	code, raw := e.call(t, http.MethodGet, "/api/v1/documents/"+docID+"/file.xlsx", e.adminToken, "")
	if code != http.StatusOK {
		t.Fatalf("файл «Движения»: код %d", code)
	}
	f, err := excelize.OpenReader(bytes.NewReader(raw))
	if err != nil {
		t.Fatalf("открыть xlsx: %v", err)
	}
	defer func() { _ = f.Close() }()
	all, err := f.GetRows("Движение")
	if err != nil {
		t.Fatalf("лист «Движение»: %v", err)
	}
	header := map[string]string{}
	for i, r := range all {
		if len(r) > 0 && r[0] == "Откуда" {
			return header, all[i+1:]
		}
		if len(r) >= 2 {
			header[r[0]] = r[1]
		}
	}
	t.Fatalf("в файле нет таблицы: %v", all)
	return nil, nil
}

// snapshot — содержимое склада так, как его загрузит терминал: где какой короб и сколько
// россыпи в какой ячейке.
func (e *putawayEnv) snapshot(t *testing.T) (boxCells map[string]string, loose map[string]string) {
	t.Helper()
	code, raw := e.call(t, http.MethodGet, "/api/v1/contents/snapshot", e.workerToken, "")
	var snap struct {
		LoadUnits []struct {
			ID     string `json:"id"`
			CellID string `json:"cell_id"`
		} `json:"load_units"`
		Loose []struct {
			CellID string `json:"cell_id"`
			Qty    string `json:"qty"`
		} `json:"loose"`
	}
	if code != http.StatusOK || json.Unmarshal(raw, &snap) != nil {
		t.Fatalf("снимок: %d %s", code, raw)
	}
	boxCells, loose = map[string]string{}, map[string]string{}
	for _, lu := range snap.LoadUnits {
		boxCells[lu.ID] = lu.CellID
	}
	for _, l := range snap.Loose {
		loose[l.CellID] = l.Qty
	}
	return boxCells, loose
}

// Полный цикл в два сеанса. Кладовщик берёт задание, разносит один короб и часть россыпи и
// жмёт «Завершить» — задание возвращается в пул остатком, в портале первое «Движение».
// Второй сеанс разносит остальное — задание выполнено, второе «Движение». После каждого
// сеанса остаток, задание, снимок терминала и документ говорят одно и то же.
func TestPutawayHTTP_fullCycleInTwoSessions(t *testing.T) {
	e := newPutawayE2E(t)
	box1, box2, task := e.receive(t)
	if task.Status != model.TaskNew || len(task.Items) != 3 {
		t.Fatalf("задание из приёмки: %+v", task)
	}
	if code, raw := e.call(t, http.MethodPost, "/api/v1/tasks/"+task.ID+"/take", e.workerToken, ""); code != http.StatusNoContent {
		t.Fatalf("взять задание: %d %s", code, raw)
	}

	// Сеанс 1: короб 1 → M1-1-1-1, 2 из 5 россыпью → M1-1-1-2.
	if got := e.operations(t, e.putaway(task.ID, uuid.NewString(),
		boxLine(box1, e.cell1), e.looseLine(2, e.cell2))); got[0] != service.StatusAccepted {
		t.Fatalf("сеанс 1: %v", got)
	}
	if s := e.stock(t); s != "15.000 / 12.000 / 2.000" {
		t.Fatalf("остаток после сеанса 1 (приёмка / M1 / M2): %s", s)
	}
	// Частичное «Завершить» отдаёт остаток в пул: задание снова «новое», без исполнителя,
	// и его видит любой кладовщик.
	after := e.tasks(t, e.worker2Token)
	if len(after) != 1 || after[0].Status != model.TaskNew || after[0].AssigneeName != "" {
		t.Fatalf("задание после частичного сеанса: %+v", after)
	}
	placed, remaining := 0, ""
	for _, it := range after[0].Items {
		if it.Placed {
			placed++
		}
		if it.LoadUnitID == nil && it.Remaining != nil {
			remaining = *it.Remaining
		}
	}
	if placed != 1 || remaining != "3" {
		t.Errorf("позиции после сеанса 1: размещено %d, остаток россыпи %q", placed, remaining)
	}
	boxCells, loose := e.snapshot(t)
	if boxCells[box1] != e.cell1 || boxCells[box2] != e.cellDefault {
		t.Errorf("снимок, короба: %v", boxCells)
	}
	// Россыпь ячейки приёмки — за вычетом короба 2, который лежит там же.
	if loose[e.cellDefault] != "3" || loose[e.cell2] != "2" {
		t.Errorf("снимок, россыпь: %v", loose)
	}
	docs := e.movementDocs(t)
	if len(docs) != 1 || docs[0]["operation"] != model.MovementOperationPutaway ||
		docs[0]["task_number"] != float64(task.Number) || docs[0]["supplier"] != "ООО «Голсера»" ||
		docs[0]["doc_number"] != "ТН-77" || docs[0]["lines_count"] != float64(2) {
		t.Fatalf("«Движение» после сеанса 1: %v", docs)
	}
	header, rows := e.movementXLSX(t, docs[0]["id"].(string))
	if header["Операция"] != "Размещение" || header["Исполнитель"] != "Кладовщик" ||
		header["Документ поставщика"] != "№ ТН-77 от 01.10.2026" {
		t.Errorf("шапка «Движения»: %v", header)
	}
	assertRows(t, rows, [][]string{
		{"С-Н-П", "M1-1-1-1", "16121", "Кальмар", "01.09.2026", "12"},
		{"С-Н-П", "M1-1-1-2", "16121", "Кальмар", "02.09.2026", "2"},
	})

	// Сеанс 2 — сменщик разносит остаток: короб 2 и 3 россыпью → M1-1-1-2.
	if got := e.operations(t, e.putaway(task.ID, uuid.NewString(),
		boxLine(box2, e.cell2), e.looseLine(3, e.cell2))); got[0] != service.StatusAccepted {
		t.Fatalf("сеанс 2: %v", got)
	}
	if s := e.stock(t); s != "0.000 / 12.000 / 17.000" {
		t.Fatalf("остаток после сеанса 2 (приёмка / M1 / M2): %s", s)
	}
	if left := e.tasks(t, e.workerToken); len(left) != 0 {
		t.Errorf("выполненное задание осталось в текущих: %+v", left)
	}
	var status string
	if err := e.pool.QueryRow(context.Background(),
		`SELECT status FROM warehouse_tasks WHERE id = $1::uuid`, task.ID).Scan(&status); err != nil || status != model.TaskDone {
		t.Errorf("статус задания: %q (%v)", status, err)
	}
	// В карточке задания — оба захода.
	code, raw := e.call(t, http.MethodGet, "/api/v1/tasks/"+task.ID, e.workerToken, "")
	var detail struct {
		Sessions []any `json:"sessions"`
	}
	if code != http.StatusOK || json.Unmarshal(raw, &detail) != nil || len(detail.Sessions) != 2 {
		t.Errorf("карточка задания: %d %s", code, raw)
	}
	boxCells, loose = e.snapshot(t)
	if boxCells[box2] != e.cell2 || loose[e.cellDefault] != "" || loose[e.cell2] != "5" {
		t.Errorf("снимок после сеанса 2: короба %v, россыпь %v", boxCells, loose)
	}
	if docs := e.movementDocs(t); len(docs) != 2 {
		t.Errorf("документов «Движение» после двух сеансов: %d", len(docs))
	}
}

// Отказы не оставляют следов. Сеанс, в котором одна строка нарушает задание, не проводится
// целиком — даже его законные строки; чужой короб и выполненное задание отклоняются. После
// всех отказов склад, задание и портал такие же, как до них.
func TestPutawayHTTP_rejectionsLeaveNoTrace(t *testing.T) {
	e := newPutawayE2E(t)
	box1, box2, task := e.receive(t)
	before := e.stock(t)

	// Законный короб + россыпи больше, чем в задании.
	if got := e.operations(t, e.putaway(task.ID, uuid.NewString(),
		boxLine(box1, e.cell1), e.looseLine(6, e.cell2))); got[0] != service.StatusRejected {
		t.Fatalf("сверх задания: %v, ожидался отказ", got)
	}
	// Законный короб не уехал вместе с отклонённым сеансом.
	if s := e.stock(t); s != before {
		t.Fatalf("отклонённый сеанс сдвинул остаток: %s, было %s", s, before)
	}
	// Короб не из задания: его приняли в ту же ячейку приёмки другой приёмкой.
	stranger := uuid.NewString()
	if got := e.operations(t, jsonf(`{"operations":[{"operation_id":%q,"kind":"receipt_submit","payload":{
		"receipt_id":%q,"warehouse_id":%q,"doc_number":"б/н","doc_date":"01-10-2026",
		"load_units":[{"id":%q,"kind":"box"}],
		"lines":[{"good_id":%q,"production_date":"01-09-2026","qty":4,"load_unit_id":%q}]}}]}`,
		uuid.NewString(), uuid.NewString(), e.warehouse, stranger, e.good, stranger)); got[0] != service.StatusAccepted {
		t.Fatalf("вторая приёмка: %v", got)
	}
	before = e.stock(t)
	if got := e.operations(t, e.putaway(task.ID, uuid.NewString(), boxLine(stranger, e.cell1))); got[0] != service.StatusRejected {
		t.Fatalf("чужой короб: %v, ожидался отказ", got)
	}
	if s := e.stock(t); s != before {
		t.Fatalf("отказы сдвинули остаток: %s, было %s", s, before)
	}
	var putaways int
	if err := e.pool.QueryRow(context.Background(), `SELECT count(*) FROM putaways`).Scan(&putaways); err != nil || putaways != 0 {
		t.Errorf("проведённых сеансов после отказов: %d (%v)", putaways, err)
	}
	if docs := e.movementDocs(t); len(docs) != 0 {
		t.Errorf("отказы оставили «Движение»: %v", docs)
	}

	// Выполненное задание больше не принимает сеансов.
	if got := e.operations(t, e.putaway(task.ID, uuid.NewString(),
		boxLine(box1, e.cell1), boxLine(box2, e.cell1), e.looseLine(5, e.cell2))); got[0] != service.StatusAccepted {
		t.Fatalf("размещение всего задания: %v", got)
	}
	if got := e.operations(t, e.putaway(task.ID, uuid.NewString(), boxLine(box1, e.cell2))); got[0] != service.StatusRejected {
		t.Fatalf("сеанс по выполненному заданию: %v, ожидался отказ", got)
	}
	if docs := e.movementDocs(t); len(docs) != 1 {
		t.Errorf("документов «Движение»: %d, ожидался один", len(docs))
	}
}

// Перехват и обрыв ответа. Кладовщик взял задание и ушёл без связи; через 8 часов задание
// считается зависшим, и его берёт сменщик. Когда связь у первого появляется, его сеанс
// принимается: это уже сделанная физическая работа. Ответ теряется, терминал шлёт тот же батч
// ещё раз — повтор получает «уже принято», товар не переезжает дважды, документ один.
func TestPutawayHTTP_hijackedTaskAndReplay(t *testing.T) {
	e := newPutawayE2E(t)
	box1, box2, task := e.receive(t)
	path := "/api/v1/tasks/" + task.ID
	if code, _ := e.call(t, http.MethodPost, path+"/take", e.workerToken, ""); code != http.StatusNoContent {
		t.Fatalf("взять задание: %d", code)
	}
	if code, _ := e.call(t, http.MethodPost, path+"/take", e.worker2Token, ""); code != http.StatusConflict {
		t.Fatalf("взять чужое свежее: %d, ожидался 409", code)
	}
	// 8 часов без отправок — задание зависло и снова видно всем «новым».
	if _, err := e.pool.Exec(context.Background(),
		`UPDATE warehouse_tasks SET last_activity_at = now() - interval '9 hours' WHERE id = $1::uuid`, task.ID); err != nil {
		t.Fatal(err)
	}
	if code, raw := e.call(t, http.MethodPost, path+"/take", e.worker2Token, ""); code != http.StatusNoContent {
		t.Fatalf("сменщик берёт зависшее: %d %s", code, raw)
	}

	batch := e.putaway(task.ID, uuid.NewString(),
		boxLine(box1, e.cell1), boxLine(box2, e.cell1), e.looseLine(5, e.cell2))
	if got := e.operations(t, batch); got[0] != service.StatusAccepted {
		t.Fatalf("сеанс первого кладовщика по перехваченному заданию: %v", got)
	}
	if got := e.operations(t, batch); got[0] != service.StatusDuplicate {
		t.Fatalf("повтор батча: %v", got)
	}
	if s := e.stock(t); s != "0.000 / 24.000 / 5.000" {
		t.Fatalf("остаток после повтора (приёмка / M1 / M2): %s", s)
	}
	var status, completedBy string
	if err := e.pool.QueryRow(context.Background(), `
		SELECT t.status, u.full_name FROM warehouse_tasks t JOIN users u ON u.id = t.completed_by
		WHERE t.id = $1::uuid`, task.ID).Scan(&status, &completedBy); err != nil ||
		status != model.TaskDone || completedBy != "Кладовщик" {
		t.Errorf("задание: %q, завершил %q (%v)", status, completedBy, err)
	}
	docs := e.movementDocs(t)
	if len(docs) != 1 {
		t.Fatalf("документов «Движение» после повтора: %d", len(docs))
	}
	header, rows := e.movementXLSX(t, docs[0]["id"].(string))
	if header["Исполнитель"] != "Кладовщик" {
		t.Errorf("исполнитель — тот, кто размещал: %q", header["Исполнитель"])
	}
	assertRows(t, rows, [][]string{
		{"С-Н-П", "M1-1-1-1", "16121", "Кальмар", "01.09.2026", "24"},
		{"С-Н-П", "M1-1-1-2", "16121", "Кальмар", "02.09.2026", "5"},
	})
}
