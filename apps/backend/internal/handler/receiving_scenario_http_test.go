package handler_test

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/xuri/excelize/v2"

	"craftwms/internal/auth"
	"craftwms/internal/handler"
	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/internal/service"
	"craftwms/internal/testutil"
)

// Сценарные тесты приёмки (P4-11D): весь путь через настоящий роутер — так, как его проходят
// терминал кладовщика и портал оператора. Обе ветки (короб и штучно) и ветка штрихкода:
// привязка незнакомого ШК, выдача внутреннего и его перепечать. Итог каждого сценария
// проверяется там, где его увидят люди: остаток, состав короба, документ «Поступление» в портале
// и сам .xlsx.

// rcvEnv — роутер со всеми сервисами пути приёмки, кладовщик (ТСД) и админ (портал).
type rcvEnv struct {
	srv         *httptest.Server
	pool        *pgxpool.Pool
	workerToken string
	adminToken  string
	warehouse   string
	cellDefault string
	cell1       string
	supplier    string
}

// newReceivingE2E собирает роутер так же, как сервер (cmd/server), но только из сервисов
// пути приёмки. Справочники заводятся с заданными id, если они переданы: эталону формата
// нужны постоянные идентификаторы.
func newReceivingE2E(t *testing.T, ids map[string]string) *rcvEnv {
	t.Helper()
	pool := testutil.StartPostgres(t)
	ctx := context.Background()
	id := func(key string) any {
		if v, ok := ids[key]; ok {
			return v
		}
		return uuid.NewString()
	}
	seed := func(sql string, args ...any) string {
		var out string
		if err := pool.QueryRow(ctx, sql, args...).Scan(&out); err != nil {
			t.Fatalf("seed %q: %v", sql, err)
		}
		return out
	}

	e := &rcvEnv{pool: pool}
	worker := seed(`INSERT INTO users (login,password_hash,full_name,role)
	                VALUES ('90000041','x','Кладовщик','employee') RETURNING id::text`)
	admin := seed(`INSERT INTO users (login,password_hash,full_name,role)
	               VALUES ('90000042','x','Оператор','admin') RETURNING id::text`)
	e.warehouse = seed(`INSERT INTO warehouses (id,code,name) VALUES ($1::uuid,'SHB','Шабулина') RETURNING id::text`, id("warehouse"))
	// Ячейку по умолчанию в бою заводят сидер и импорт; здесь — тем же флагом, по которому её
	// ищет приёмка.
	e.cellDefault = seed(`INSERT INTO cells (id,warehouse_id,address,is_default)
	                      VALUES ($1::uuid,$2::uuid,'С-Н-П',true) RETURNING id::text`, id("cell_default"), e.warehouse)
	e.cell1 = seed(`INSERT INTO cells (id,warehouse_id,address) VALUES ($1::uuid,$2::uuid,'M1-1-1-1') RETURNING id::text`,
		id("cell1"), e.warehouse)
	e.supplier = seed(`INSERT INTO suppliers (id,name) VALUES ($1::uuid,'ООО «Голсера»') RETURNING id::text`, id("supplier"))

	tokens := auth.NewTokenManager("test-secret", time.Hour, 24*time.Hour)
	var err error
	if e.workerToken, err = tokens.IssueAccess(worker, string(model.RoleEmployee)); err != nil {
		t.Fatalf("токен кладовщика: %v", err)
	}
	if e.adminToken, err = tokens.IssueAccess(admin, string(model.RoleAdmin)); err != nil {
		t.Fatalf("токен оператора: %v", err)
	}

	router := handler.NewRouter(slog.New(slog.NewTextHandler(io.Discard, nil)), nil, tokens, handler.Services{
		Operations: service.NewOperationsService(repository.NewOperationsRepository(pool)),
		Barcode:    service.NewBarcodeService(repository.NewBarcodeRepository(pool)),
		Document:   service.NewDocumentService(repository.NewReportDocumentRepository(pool)),
		LoadUnit:   service.NewLoadUnitService(repository.NewLoadUnitRepository(pool)),
		Receipt: service.NewReceiptService(repository.NewReceiptRepository(pool),
			repository.NewCellRepository(pool)),
		Task:     service.NewTaskService(repository.NewTaskRepository(pool)),
		Contents: service.NewContentsService(repository.NewContentsRepository(pool)),
	})
	e.srv = httptest.NewServer(router)
	t.Cleanup(e.srv.Close)
	return e
}

// call выполняет запрос и возвращает код и сырое тело.
func (e *rcvEnv) call(t *testing.T, method, path, token, body string) (int, []byte) {
	t.Helper()
	var reader io.Reader
	if body != "" {
		reader = bytes.NewBufferString(body)
	}
	req, err := http.NewRequestWithContext(context.Background(), method, e.srv.URL+path, reader)
	if err != nil {
		t.Fatalf("запрос: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	defer func() { _ = resp.Body.Close() }()
	raw, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, raw
}

// operations отправляет батч от имени терминала и возвращает статусы операций по порядку.
func (e *rcvEnv) operations(t *testing.T, batch string) []string {
	t.Helper()
	code, raw := e.call(t, http.MethodPost, "/api/v1/operations", e.workerToken, batch)
	if code != http.StatusOK {
		t.Fatalf("батч: код %d, %s", code, raw)
	}
	var body struct {
		Results []struct {
			Status string `json:"status"`
			Error  string `json:"error"`
		} `json:"results"`
	}
	if err := json.Unmarshal(raw, &body); err != nil {
		t.Fatalf("разбор ответа батча: %v", err)
	}
	out := make([]string, 0, len(body.Results))
	for _, r := range body.Results {
		if r.Status == service.StatusRejected {
			t.Logf("отказ: %s", r.Error)
		}
		out = append(out, r.Status)
	}
	return out
}

// receiptDocs — документы «Поступление» глазами портала.
func (e *rcvEnv) receiptDocs(t *testing.T) []map[string]any {
	t.Helper()
	code, raw := e.call(t, http.MethodGet, "/api/v1/documents?kind="+model.ReportKindReceipt, e.adminToken, "")
	if code != http.StatusOK {
		t.Fatalf("список документов: код %d", code)
	}
	var out []map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("разбор списка документов: %v", err)
	}
	return out
}

// xlsxRows скачивает документ из портала и возвращает строки таблицы товаров (под шапкой).
func (e *rcvEnv) xlsxRows(t *testing.T, docID string) (header map[string]string, rows [][]string) {
	t.Helper()
	code, raw := e.call(t, http.MethodGet, "/api/v1/documents/"+docID+"/file.xlsx", e.adminToken, "")
	if code != http.StatusOK {
		t.Fatalf("файл документа: код %d", code)
	}
	f, err := excelize.OpenReader(bytes.NewReader(raw))
	if err != nil {
		t.Fatalf("открыть xlsx: %v", err)
	}
	defer func() { _ = f.Close() }()
	all, err := f.GetRows("Поступление")
	if err != nil {
		t.Fatalf("лист «Поступление»: %v", err)
	}
	header = map[string]string{}
	for i, r := range all {
		if len(r) > 0 && r[0] == "Ячейка" {
			return header, all[i+1:]
		}
		if len(r) >= 2 {
			header[r[0]] = r[1]
		}
	}
	t.Fatalf("в файле нет таблицы товаров: %v", all)
	return nil, nil
}

// qtyIn — остаток товара в ячейке, сложенный по партиям и внутренним складам.
func (e *rcvEnv) qtyIn(t *testing.T, cell, good string) string {
	t.Helper()
	var q string
	if err := e.pool.QueryRow(context.Background(), `
		SELECT COALESCE(sum(qty),0)::text FROM stock WHERE cell_id=$1::uuid AND good_id=$2::uuid`,
		cell, good).Scan(&q); err != nil {
		t.Fatalf("остаток: %v", err)
	}
	return q
}

// Эталон формата приёмки — вторая половина контракта (первая — receipt_wire_contract_test.dart
// в приложении): настоящий роутер применяет РОВНО то тело, которое шлёт ТСД, и по нему
// рождается документ с верным содержимым.
func TestReceivingHTTP_clientWireFormat(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "receipt_submit.json"))
	if err != nil {
		t.Fatalf("эталон не читается: %v", err)
	}
	var fixture struct {
		Operations []struct {
			Payload struct {
				WarehouseID string `json:"warehouse_id"`
				SupplierID  string `json:"supplier_id"`
				LoadUnits   []struct {
					ID string `json:"id"`
				} `json:"load_units"`
				Lines []struct {
					GoodID string `json:"good_id"`
					CellID string `json:"cell_id"`
				} `json:"lines"`
			} `json:"payload"`
		} `json:"operations"`
	}
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatalf("эталон не разбирается: %v", err)
	}
	p := fixture.Operations[0].Payload
	e := newReceivingE2E(t, map[string]string{
		"warehouse": p.WarehouseID, "supplier": p.SupplierID, "cell1": p.Lines[0].CellID,
	})
	if _, err := e.pool.Exec(context.Background(),
		`INSERT INTO goods (id,code,name,uom) VALUES ($1::uuid,'16121','Кальмар','шт')`, p.Lines[0].GoodID); err != nil {
		t.Fatalf("товар эталона: %v", err)
	}

	if got := e.operations(t, string(raw)); len(got) != 1 || got[0] != service.StatusAccepted {
		t.Fatalf("эталонная приёмка не применилась: %v.\n"+
			"Формат разошёлся — сверьте testdata/receipt_submit.json с тем, что шлёт клиент.", got)
	}
	docs := e.receiptDocs(t)
	if len(docs) != 1 {
		t.Fatalf("документов «Поступление»: %d", len(docs))
	}
	header, rows := e.xlsxRows(t, docs[0]["id"].(string))
	if header["Поставщик"] != "ООО «Голсера»" || header["Исполнитель"] != "Кладовщик" {
		t.Fatalf("шапка документа: %v", header)
	}
	want := [][]string{
		{"M1-1-1-1", "16121", "Кальмар", "01.09.2026", "12"},
		{"С-Н-П", "16121", "Кальмар", "02.09.2026", "3"},
	}
	assertRows(t, rows, want)

	// Короб эталона размещён в своей ячейке со своим составом. Без этой проверки сервер не
	// заметил бы, что строка потеряла ссылку на короб: она стала бы россыпью той же ячейки,
	// и документ остался бы прежним.
	var status, cell, qty string
	if err := e.pool.QueryRow(context.Background(), `
		SELECT lu.status, COALESCE(lu.cell_id::text, ''), COALESCE(sum(c.qty),0)::text
		FROM load_units lu LEFT JOIN lu_content c ON c.load_unit_id = lu.id
		WHERE lu.id = $1::uuid GROUP BY lu.status, lu.cell_id`, p.LoadUnits[0].ID).Scan(&status, &cell, &qty); err != nil {
		t.Fatalf("короб эталона: %v", err)
	}
	if status != model.LoadUnitPlaced || cell != e.cell1 || qty != "12.000" {
		t.Fatalf("короб эталона: статус %q, ячейка %s, состав %s", status, cell, qty)
	}
}

// Ветка «штучно» + незнакомый ШК. Кладовщик без связи сканирует код, которого нет
// в справочнике, выбирает товар руками и принимает его россыпью. Когда связь появляется,
// очередь доставляет одним батчем и привязку, и приёмку. После этого код опознаёт товар,
// остаток лёг в ячейку по умолчанию, документ — в портале.
func TestReceivingHTTP_looseWithNewBarcode(t *testing.T) {
	e := newReceivingE2E(t, nil)
	good := seedGood(t, e.pool, "Креветка")
	const code = "4607044662964"

	got := e.operations(t, jsonf(`{"operations":[
		{"operation_id":%q,"kind":"bind_barcode","payload":{"good_id":%q,"barcode":%q}},
		{"operation_id":%q,"kind":"receipt_submit","payload":{
			"receipt_id":%q,"warehouse_id":%q,
			"lines":[{"good_id":%q,"production_date":"01-09-2026","qty":5}]}}]}`,
		uuid.NewString(), good, code,
		uuid.NewString(), uuid.NewString(), e.warehouse, good))
	if strings.Join(got, ",") != "accepted,accepted" {
		t.Fatalf("батч: %v", got)
	}

	status, raw := e.call(t, http.MethodGet, "/api/v1/barcodes/"+code, e.workerToken, "")
	if status != http.StatusOK || !strings.Contains(string(raw), good) {
		t.Fatalf("ШК после привязки не опознаёт товар: %d %s", status, raw)
	}
	if q := e.qtyIn(t, e.cellDefault, good); q != "5.000" {
		t.Fatalf("остаток в ячейке по умолчанию: %s", q)
	}
	docs := e.receiptDocs(t)
	if len(docs) != 1 || docs[0]["supplier"] != "" {
		t.Fatalf("документ приёмки без поставщика: %+v", docs)
	}
	header, rows := e.xlsxRows(t, docs[0]["id"].(string))
	if header["Поставщик"] != "без поставщика" {
		t.Fatalf("поставщик в шапке: %q", header["Поставщик"])
	}
	assertRows(t, rows, [][]string{{"С-Н-П", "", "Креветка", "01.09.2026", "5"}})
}

// Ветка «короб» + товар без ШК. Кладовщик выдаёт товару внутренний ШК (это только по сети),
// печатает ярлык, потом ярлык портится — перепечать даёт тот же код, второй не заводится.
// Товар кладётся в два короба в M1-1-1-1; в документе короба складываются в одну строку,
// а сами короба размещены с верным составом.
func TestReceivingHTTP_boxesWithInternalBarcode(t *testing.T) {
	e := newReceivingE2E(t, nil)
	good := seedGood(t, e.pool, "Кальмар")

	issue := func() (string, bool) {
		status, raw := e.call(t, http.MethodPost, "/api/v1/goods/"+good+"/barcode", e.workerToken, "")
		if status != http.StatusOK {
			t.Fatalf("выдача внутреннего ШК: %d %s", status, raw)
		}
		var out struct {
			Barcode   string `json:"barcode"`
			Generated bool   `json:"generated"`
		}
		if err := json.Unmarshal(raw, &out); err != nil {
			t.Fatalf("разбор выдачи: %v", err)
		}
		return out.Barcode, out.Generated
	}
	code, generated := issue()
	if !generated || len(code) != 13 || code[:2] != "20" {
		t.Fatalf("внутренний ШК: %q, создан=%v", code, generated)
	}
	// Перепечать испорченного ярлыка: тот же код, нового не заводится.
	if again, gen := issue(); again != code || gen {
		t.Fatalf("перепечать: %q (создан=%v), ждали прежний %q", again, gen, code)
	}
	if status, raw := e.call(t, http.MethodGet, "/api/v1/barcodes/"+code, e.workerToken, ""); status != http.StatusOK ||
		!strings.Contains(string(raw), good) {
		t.Fatalf("внутренний ШК не опознаёт товар: %d %s", status, raw)
	}

	box1, box2 := uuid.NewString(), uuid.NewString()
	got := e.operations(t, jsonf(`{"operations":[{"operation_id":%q,"kind":"receipt_submit","payload":{
		"receipt_id":%q,"warehouse_id":%q,"supplier_id":%q,
		"load_units":[{"id":%q,"kind":"box"},{"id":%q,"kind":"box"}],
		"lines":[
			{"good_id":%q,"production_date":"01-09-2026","cell_id":%q,"load_unit_id":%q,"qty":12},
			{"good_id":%q,"production_date":"01-09-2026","cell_id":%q,"load_unit_id":%q,"qty":12}]}}]}`,
		uuid.NewString(), uuid.NewString(), e.warehouse, e.supplier, box1, box2,
		good, e.cell1, box1, good, e.cell1, box2))
	if strings.Join(got, ",") != "accepted" {
		t.Fatalf("приёмка: %v", got)
	}

	if q := e.qtyIn(t, e.cell1, good); q != "24.000" {
		t.Fatalf("остаток в M1-1-1-1: %s", q)
	}
	for _, box := range []string{box1, box2} {
		status, raw := e.call(t, http.MethodGet, "/api/v1/load-units/"+box, e.workerToken, "")
		if status != http.StatusOK || !strings.Contains(string(raw), `"placed"`) || !strings.Contains(string(raw), e.cell1) {
			t.Fatalf("короб %s: %d %s", box, status, raw)
		}
	}
	docs := e.receiptDocs(t)
	if len(docs) != 1 {
		t.Fatalf("документов: %d", len(docs))
	}
	_, rows := e.xlsxRows(t, docs[0]["id"].(string))
	assertRows(t, rows, [][]string{{"M1-1-1-1", "", "Кальмар", "01.09.2026", "24"}})
}

// Обрыв ответа: терминал не получил подтверждение и прислал тот же батч ещё раз. Приход не
// удваивается, документ один, повтор получает тот же ответ, что и первая попытка.
func TestReceivingHTTP_replayAfterLostResponse(t *testing.T) {
	e := newReceivingE2E(t, nil)
	good := seedGood(t, e.pool, "Кальмар")
	batch := jsonf(`{"operations":[{"operation_id":%q,"kind":"receipt_submit","payload":{
		"receipt_id":%q,"warehouse_id":%q,
		"lines":[{"good_id":%q,"production_date":"01-09-2026","qty":7}]}}]}`,
		uuid.NewString(), uuid.NewString(), e.warehouse, good)

	if got := e.operations(t, batch); got[0] != service.StatusAccepted {
		t.Fatalf("первая отправка: %v", got)
	}
	if got := e.operations(t, batch); got[0] != service.StatusDuplicate {
		t.Fatalf("повтор: %v", got)
	}
	if q := e.qtyIn(t, e.cellDefault, good); q != "7.000" {
		t.Fatalf("приход удвоился: %s", q)
	}
	if docs := e.receiptDocs(t); len(docs) != 1 {
		t.Fatalf("документов после повтора: %d", len(docs))
	}
}

// assertRows сравнивает строки таблицы товаров .xlsx с ожидаемыми.
func assertRows(t *testing.T, got, want [][]string) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("строк в документе %d, ждали %d: %v", len(got), len(want), got)
	}
	for i := range want {
		// excelize обрезает пустые хвостовые ячейки, а пустой код в середине строки сохраняет.
		if strings.Join(got[i], "|") != strings.Join(want[i], "|") {
			t.Fatalf("строка %d: %v, ждали %v", i, got[i], want[i])
		}
	}
}
