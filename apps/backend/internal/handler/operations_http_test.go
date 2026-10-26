package handler_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/auth"
	"craftwms/internal/handler"
	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/internal/service"
	"craftwms/internal/testutil"
)

// Сквозной приём операций очереди через НАСТОЯЩИЙ HTTP-слой (P2-08).
//
// Сервисный слой покрыт в P2-05, но между ним и устройством лежит то, что не проверялось ничем,
// кроме ручного curl: разбор тела запроса, авторизация, коды ответов и форма ответа. Разъедься
// имя поля или код — сервисные тесты остались бы зелёными, а терминал молча перестал бы
// синхронизироваться.

// e2eEnv — поднятый роутер с настоящей БД и настоящей авторизацией.
type e2eEnv struct {
	srv   *httptest.Server
	pool  *pgxpool.Pool
	token string
	user  string
}

// newE2E собирает роутер ровно так же, как cmd/server: тот же конструктор, те же middleware.
func newE2E(t *testing.T) *e2eEnv {
	t.Helper()
	pool := testutil.StartPostgres(t)
	ctx := context.Background()

	tokens := auth.NewTokenManager("test-secret", time.Hour, 24*time.Hour)

	var userID string
	err := pool.QueryRow(ctx,
		`INSERT INTO users (login, password_hash, full_name,position_id)
		 VALUES ('90000001','x','Кладовщик','7a000000-0000-4000-8000-000000000002') RETURNING id::text`).Scan(&userID)
	if err != nil {
		t.Fatalf("seed user: %v", err)
	}
	token, err := tokens.IssueAccess(userID, string(model.RoleEmployee))
	if err != nil {
		t.Fatalf("issue token: %v", err)
	}

	opsSvc := service.NewOperationsService(repository.NewOperationsRepository(pool))
	router := handler.NewRouter(
		slog.New(slog.NewTextHandler(io.Discard, nil)), nil, tokens,
		handler.Services{Operations: opsSvc, Rights: repository.NewUserRepository(pool)},
	)
	srv := httptest.NewServer(router)
	t.Cleanup(srv.Close)

	return &e2eEnv{srv: srv, pool: pool, token: token, user: userID}
}

// post отправляет батч операций и возвращает код и разобранное тело.
func (e *e2eEnv) post(t *testing.T, body string, withToken bool) (int, map[string]any) {
	t.Helper()
	req, err := http.NewRequestWithContext(context.Background(),
		http.MethodPost, e.srv.URL+"/api/v1/operations", bytes.NewBufferString(body))
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if withToken {
		req.Header.Set("Authorization", "Bearer "+e.token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do request: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()

	var parsed map[string]any
	raw, _ := io.ReadAll(resp.Body)
	if len(raw) > 0 {
		_ = json.Unmarshal(raw, &parsed)
	}
	return resp.StatusCode, parsed
}

// results достаёт список исходов операций из ответа.
func results(t *testing.T, body map[string]any) []map[string]any {
	t.Helper()
	raw, ok := body["results"].([]any)
	if !ok {
		t.Fatalf("в ответе нет results: %+v", body)
	}
	out := make([]map[string]any, 0, len(raw))
	for _, item := range raw {
		out = append(out, item.(map[string]any))
	}
	return out
}

// seedGood вставляет товар и возвращает его id.
func seedGood(t *testing.T, pool *pgxpool.Pool, name string) string {
	t.Helper()
	var id string
	if err := pool.QueryRow(context.Background(),
		`INSERT INTO goods (name, uom) VALUES ($1,'шт') RETURNING id::text`, name).Scan(&id); err != nil {
		t.Fatalf("seed good: %v", err)
	}
	return id
}

func TestOperationsHTTP_unauthorized(t *testing.T) {
	env := newE2E(t)

	code, _ := env.post(t, `{"operations":[]}`, false)

	if code != http.StatusUnauthorized {
		t.Fatalf("без токена ждали 401, получили %d", code)
	}
}

// Главный сквозной случай: переотправка не двоит данные — на уровне HTTP, а не сервиса.
func TestOperationsHTTP_replayIsIdempotent(t *testing.T) {
	env := newE2E(t)
	good := seedGood(t, env.pool, "Снек")
	const body = `{"operations":[{"operation_id":"aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa",` +
		`"kind":"bind_barcode","payload":{"good_id":"%s","barcode":"4600000000031","symbology":"ean13"}}]}`
	payload := jsonf(body, good)

	code, first := env.post(t, payload, true)
	if code != http.StatusOK {
		t.Fatalf("первая отправка: ждали 200, получили %d (%+v)", code, first)
	}
	if got := results(t, first)[0]["status"]; got != service.StatusAccepted {
		t.Fatalf("первая отправка: ждали accepted, получили %v", got)
	}

	code, second := env.post(t, payload, true)
	if code != http.StatusOK {
		t.Fatalf("переотправка: ждали 200, получили %d", code)
	}
	if got := results(t, second)[0]["status"]; got != service.StatusDuplicate {
		t.Fatalf("переотправка: ждали duplicate, получили %v", got)
	}

	var n int
	if err := env.pool.QueryRow(context.Background(),
		`SELECT count(*) FROM barcodes WHERE barcode='4600000000031'`).Scan(&n); err != nil {
		t.Fatalf("count: %v", err)
	}
	if n != 1 {
		t.Fatalf("привязок в базе %d, ждали 1", n)
	}
}

// Отказ по существу приезжает с причиной и не мешает следующей операции батча.
func TestOperationsHTTP_rejectionDoesNotStopBatch(t *testing.T) {
	env := newE2E(t)
	goodA := seedGood(t, env.pool, "Товар A")
	goodB := seedGood(t, env.pool, "Товар B")

	code, _ := env.post(t, jsonf(`{"operations":[{"operation_id":"bbbbbbbb-1111-4111-8111-bbbbbbbbbbbb",`+
		`"kind":"bind_barcode","payload":{"good_id":"%s","barcode":"4600000000048"}}]}`, goodA), true)
	if code != http.StatusOK {
		t.Fatalf("подготовка: %d", code)
	}

	code, body := env.post(t, jsonf(`{"operations":[`+
		`{"operation_id":"cccccccc-1111-4111-8111-cccccccccccc","kind":"bind_barcode","payload":{"good_id":"%s","barcode":"4600000000048"}},`+
		`{"operation_id":"dddddddd-1111-4111-8111-dddddddddddd","kind":"bind_barcode","payload":{"good_id":"%s","barcode":"4600000000055"}}]}`,
		goodB, goodB), true)
	if code != http.StatusOK {
		t.Fatalf("батч: %d", code)
	}
	res := results(t, body)
	if len(res) != 2 {
		t.Fatalf("ждали 2 исхода, получили %d", len(res))
	}
	if res[0]["status"] != service.StatusRejected {
		t.Fatalf("первая: ждали rejected, получили %v", res[0]["status"])
	}
	if res[0]["error"] == "" || res[0]["error"] == nil {
		t.Fatal("у отклонённой пустая причина — на экране разбора показывать нечего")
	}
	if res[1]["status"] != service.StatusAccepted {
		t.Fatalf("вторая: ждали accepted, получили %v", res[1]["status"])
	}
}

func TestOperationsHTTP_badRequests(t *testing.T) {
	env := newE2E(t)

	if code, _ := env.post(t, `{"operations":[]}`, true); code != http.StatusBadRequest {
		t.Fatalf("пустой батч: ждали 400, получили %d", code)
	}
	if code, _ := env.post(t, `{`, true); code != http.StatusBadRequest {
		t.Fatalf("битый JSON: ждали 400, получили %d", code)
	}
	// Неизвестный тип — отказ по существу внутри 200, а не 400: батч разобран, а конкретная
	// операция неисполнима. Иначе устройство сочло бы неудачей весь батч и повторяло бы его.
	code, body := env.post(t, `{"operations":[{"operation_id":"eeeeeeee-1111-4111-8111-eeeeeeeeeeee",`+
		`"kind":"teleport_goods","payload":{}}]}`, true)
	if code != http.StatusOK {
		t.Fatalf("неизвестный тип: ждали 200, получили %d", code)
	}
	if got := results(t, body)[0]["status"]; got != service.StatusRejected {
		t.Fatalf("неизвестный тип: ждали rejected, получили %v", got)
	}
}

// jsonf собирает тело запроса из шаблона.
func jsonf(format string, args ...any) string {
	return fmt.Sprintf(format, args...)
}

// seedWarehouseCell готовит склад и ячейку для прохода.
func seedWarehouseCell(t *testing.T, pool *pgxpool.Pool) (string, string) {
	t.Helper()
	ctx := context.Background()
	var warehouse, cell string
	if err := pool.QueryRow(ctx,
		`INSERT INTO warehouses (code,name) VALUES ('SHB','Шабулина') RETURNING id::text`).Scan(&warehouse); err != nil {
		t.Fatalf("seed warehouse: %v", err)
	}
	if err := pool.QueryRow(ctx,
		`INSERT INTO cells (warehouse_id,address) VALUES ($1::uuid,'M1-1-1-1') RETURNING id::text`,
		warehouse).Scan(&cell); err != nil {
		t.Fatalf("seed cell: %v", err)
	}
	return warehouse, cell
}

// Сквозной сценарий P2: проход накоплен офлайн → связь появилась → батч ушёл целиком → остаток
// в БД. Затем ответ «теряется», и устройство шлёт тот же батч снова: данные не двоятся, а финал
// отдаёт исходный ответ, а не отказ «сессия уже закрыта».
func TestOperationsHTTP_stockEntryFullCycle(t *testing.T) {
	env := newE2E(t)
	ctx := context.Background()
	warehouse, cell := seedWarehouseCell(t, env.pool)
	good := seedGood(t, env.pool, "Кальмары")

	const session = "5e551011-0000-4000-8000-000000000001"
	batch := jsonf(`{"operations":[
		{"operation_id":"0a000000-0000-4000-8000-000000000001","kind":"stock_entry_start",
		 "payload":{"session_id":"%s","warehouse_id":"%s"}},
		{"operation_id":"0a000000-0000-4000-8000-000000000002","kind":"stock_entry_checkpoint",
		 "payload":{"session_id":"%s","cell_id":"%s",
		   "lines":[{"good_id":"%s","production_date":"14-08-2026","qty":"12.5"}],
		   "new_barcodes":[{"good_id":"%s","barcode":"4600000000079","symbology":"ean13"}]}},
		{"operation_id":"0a000000-0000-4000-8000-000000000003","kind":"stock_entry_finalize",
		 "payload":{"session_id":"%s"}}]}`,
		session, warehouse, session, cell, good, good, session)

	code, body := env.post(t, batch, true)
	if code != http.StatusOK {
		t.Fatalf("первый проход: ждали 200, получили %d (%+v)", code, body)
	}
	res := results(t, body)
	if len(res) != 3 {
		t.Fatalf("ждали 3 исхода, получили %d", len(res))
	}
	for i, r := range res {
		if r["status"] != service.StatusAccepted {
			t.Fatalf("операция %d: ждали accepted, получили %v (%v)", i, r["status"], r["error"])
		}
	}

	// Остаток записан ровно тот, что просчитали.
	var qty string
	if err := env.pool.QueryRow(ctx, `
		SELECT s.qty::text FROM stock s
		JOIN batches b ON b.id = s.batch_id
		WHERE s.cell_id=$1::uuid AND s.good_id=$2::uuid AND b.production_date='2026-08-14'`,
		cell, good).Scan(&qty); err != nil {
		t.Fatalf("остаток не записан: %v", err)
	}
	if qty != "12.500" {
		t.Fatalf("остаток %s, ждали 12.500", qty)
	}

	// Ответ до устройства не дошёл — очередь шлёт тот же батч заново.
	code, replayBody := env.post(t, batch, true)
	if code != http.StatusOK {
		t.Fatalf("повтор: ждали 200, получили %d", code)
	}
	for i, r := range results(t, replayBody) {
		if r["status"] != service.StatusDuplicate {
			t.Fatalf("повтор операции %d: ждали duplicate, получили %v (%v)", i, r["status"], r["error"])
		}
	}

	// Ничего не удвоилось: одна сессия, одна строка, тот же остаток.
	var sessions, lines int
	if err := env.pool.QueryRow(ctx, `SELECT count(*) FROM stock_entry_sessions`).Scan(&sessions); err != nil {
		t.Fatalf("count sessions: %v", err)
	}
	if err := env.pool.QueryRow(ctx, `SELECT count(*) FROM stock_entry_lines`).Scan(&lines); err != nil {
		t.Fatalf("count lines: %v", err)
	}
	if sessions != 1 || lines != 1 {
		t.Fatalf("после повтора сессий %d, строк %d — ждали 1 и 1", sessions, lines)
	}
	var after string
	if err := env.pool.QueryRow(ctx,
		`SELECT qty::text FROM stock WHERE cell_id=$1::uuid AND good_id=$2::uuid`, cell, good).Scan(&after); err != nil {
		t.Fatalf("остаток после повтора: %v", err)
	}
	if after != "12.500" {
		t.Fatalf("остаток после повтора %s — переотправка изменила данные", after)
	}
}

// Вторая половина контракта формата (P2-08): настоящий роутер применяет РОВНО то тело,
// которое шлёт приложение ТСД.
//
// Файл `testdata/outbox_batch.json` снят с настоящего клиента; на него же смотрит тест
// `wire_contract_test.dart` в приложении. До этого формат утверждался дважды независимо —
// здесь структурами Go, там написанным руками JSON, — и разойдись имя поля, обе стороны
// остались бы зелёными, а терминал молча перестал бы синхронизироваться.
func TestOperationsHTTP_clientWireFormat(t *testing.T) {
	env := newE2E(t)
	ctx := context.Background()

	raw, err := os.ReadFile(filepath.Join("testdata", "outbox_batch.json"))
	if err != nil {
		t.Fatalf("эталон формата не читается: %v", err)
	}

	// Товар заводим с тем же id, что в эталоне: подстановка значений превратила бы проверку
	// формата в проверку подстановки.
	var fixture struct {
		Operations []struct {
			Payload struct {
				GoodID string `json:"good_id"`
			} `json:"payload"`
		} `json:"operations"`
	}
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatalf("эталон не разбирается: %v", err)
	}
	goodID := fixture.Operations[0].Payload.GoodID
	if _, err := env.pool.Exec(ctx,
		`INSERT INTO goods (id, name, uom) VALUES ($1::uuid,'Арахис жареный','шт')`, goodID); err != nil {
		t.Fatalf("seed good %s: %v", goodID, err)
	}

	code, body := env.post(t, string(raw), true)

	if code != http.StatusOK {
		t.Fatalf("эталонный батч отвергнут: %d (%+v)", code, body)
	}
	res := results(t, body)
	if len(res) != len(fixture.Operations) {
		t.Fatalf("исходов %d, операций в эталоне %d", len(res), len(fixture.Operations))
	}
	for i, r := range res {
		if r["status"] != service.StatusAccepted {
			t.Fatalf("операция %d из эталона не применилась: %v (%v).\n"+
				"Формат разошёлся — сверьте testdata/outbox_batch.json с тем, что шлёт клиент.",
				i, r["status"], r["error"])
		}
	}
}
