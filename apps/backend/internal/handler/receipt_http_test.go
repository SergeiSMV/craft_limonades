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
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/auth"
	"craftwms/internal/handler"
	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/internal/service"
	"craftwms/internal/testutil"
)

// Полный цикл приёмки через НАСТОЯЩИЙ HTTP-слой (P4-03) — это и есть критерий задачи.
//
// Домен покрыт в P4-02, но между ним и терминалом лежит то, что сервисные тесты не видят:
// разбор тела, авторизация, коды ответов и подстановка дефолтной ячейки. Разъедься имя поля
// или код ответа — сервисные тесты остались бы зелёными, а приёмка на ТСД не работала бы.

// rcEnv — поднятый роутер с настоящей БД и настоящей авторизацией.
type rcHTTPEnv struct {
	srv       *httptest.Server
	pool      *pgxpool.Pool
	token     string
	warehouse string
	cellDflt  string
	cell      string
	good      string
}

// newReceiptE2E собирает роутер ровно так же, как cmd/server: тот же конструктор, те же middleware.
func newReceiptE2E(t *testing.T) *rcHTTPEnv {
	t.Helper()
	pool := testutil.StartPostgres(t)
	ctx := context.Background()
	tokens := auth.NewTokenManager("test-secret", time.Hour, 24*time.Hour)

	scan := func(sql string, args ...any) string {
		var id string
		if err := pool.QueryRow(ctx, sql, args...).Scan(&id); err != nil {
			t.Fatalf("seed %q: %v", sql, err)
		}
		return id
	}
	userID := scan(`INSERT INTO users (login,password_hash,full_name,role)
	                VALUES ('90000041','x','Кладовщик','employee') RETURNING id::text`)
	token, err := tokens.IssueAccess(userID, string(model.RoleEmployee))
	if err != nil {
		t.Fatalf("issue token: %v", err)
	}

	e := &rcHTTPEnv{pool: pool, token: token}
	e.warehouse = scan(`INSERT INTO warehouses (code,name) VALUES ('SHB','Шабулина') RETURNING id::text`)
	e.cell = scan(`INSERT INTO cells (warehouse_id,address) VALUES ($1::uuid,'M1-1-1-1') RETURNING id::text`, e.warehouse)
	e.good = scan(`INSERT INTO goods (name,uom) VALUES ('Кальмар','шт') RETURNING id::text`)

	cells := repository.NewCellRepository(pool)
	if err := repository.WithinTx(ctx, pool, func(q repository.Querier) error {
		var err error
		e.cellDflt, err = cells.EnsureDefault(ctx, q, e.warehouse)
		return err
	}); err != nil {
		t.Fatalf("дефолтная ячейка: %v", err)
	}

	// Приёмке нужен и справочник ШК: сквозной тест проходит привязку неизвестного кода.
	router := handler.NewRouter(
		slog.New(slog.NewTextHandler(io.Discard, nil)), nil, tokens,
		handler.Services{
			Barcode:  service.NewBarcodeService(repository.NewBarcodeRepository(pool)),
			Receipt:  service.NewReceiptService(repository.NewReceiptRepository(pool), cells),
			LoadUnit: service.NewLoadUnitService(repository.NewLoadUnitRepository(pool)),
		},
	)
	srv := httptest.NewServer(router)
	t.Cleanup(srv.Close)
	e.srv = srv
	return e
}

// do отправляет запрос с токеном и возвращает код и разобранное тело.
func (e *rcHTTPEnv) do(t *testing.T, method, path, body string) (int, map[string]any) {
	t.Helper()
	var rdr io.Reader
	if body != "" {
		rdr = bytes.NewBufferString(body)
	}
	req, err := http.NewRequestWithContext(context.Background(), method, e.srv.URL+path, rdr)
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+e.token)
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

// stockQty читает остаток в ячейке на складе по умолчанию — туда приходует приёмка.
func (e *rcHTTPEnv) stockQty(t *testing.T, cellID string) string {
	t.Helper()
	var qty string
	err := e.pool.QueryRow(context.Background(), `
		SELECT coalesce(sum(s.qty),0)::text FROM stock s
		JOIN internal_warehouses w ON w.id = s.internal_warehouse_id AND w.is_default
		WHERE s.cell_id = $1::uuid`, cellID).Scan(&qty)
	if err != nil {
		t.Fatalf("остаток: %v", err)
	}
	return qty
}

func TestReceiptHTTP_unauthorized(t *testing.T) {
	e := newReceiptE2E(t)
	req, err := http.NewRequestWithContext(context.Background(), http.MethodPost,
		e.srv.URL+"/api/v1/receipts", bytes.NewBufferString(`{}`))
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do request: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("без токена ждали 401, получили %d", resp.StatusCode)
	}
}

// Ветка «россыпь»: скан неизвестного ШК → привязка → строка без ячейки → оприходование.
// Ячейку кладовщик не указывает — товар обязан лечь в дефолтную.
func TestReceiptHTTP_looseGoodsWithBarcodeBinding(t *testing.T) {
	e := newReceiptE2E(t)
	const barcode = "4600000000048"

	// Скан кода, которого система не знает: устройство спрашивает и получает 404.
	if code, _ := e.do(t, http.MethodGet, "/api/v1/barcodes/"+barcode, ""); code != http.StatusNotFound {
		t.Fatalf("неизвестный ШК: ждали 404, получили %d", code)
	}
	// Кладовщик выбирает товар — привязка идёт существующей ручкой (P-FS-03), своей у приёмки нет.
	bind := fmt.Sprintf(`{"good_id":%q,"barcode":%q,"symbology":"ean13"}`, e.good, barcode)
	if code, body := e.do(t, http.MethodPost, "/api/v1/barcodes", bind); code != http.StatusCreated && code != http.StatusOK {
		t.Fatalf("привязка ШК: код %d, тело %+v", code, body)
	}
	// Теперь тот же скан опознаётся товаром: ручка отдаёт карточку товара целиком (P-FS-03),
	// поэтому идентификатор лежит в id, а не в good_id.
	code, body := e.do(t, http.MethodGet, "/api/v1/barcodes/"+barcode, "")
	if code != http.StatusOK || body["id"] != e.good {
		t.Fatalf("после привязки: код %d, тело %+v", code, body)
	}

	receipt := uuid.NewString()
	create := fmt.Sprintf(`{"receipt_id":%q,"warehouse_id":%q}`, receipt, e.warehouse)
	if code, body := e.do(t, http.MethodPost, "/api/v1/receipts", create); code != http.StatusCreated {
		t.Fatalf("создать приёмку: код %d, тело %+v", code, body)
	}

	// Строка без ячейки: сервер подставляет дефолтную и ОБЯЗАН вернуть, какую именно.
	line := fmt.Sprintf(`{"good_id":%q,"production_date":"15-01-2026","qty":"12.5"}`, e.good)
	code, body = e.do(t, http.MethodPost, "/api/v1/receipts/"+receipt+"/lines", line)
	if code != http.StatusOK {
		t.Fatalf("строка приёмки: код %d, тело %+v", code, body)
	}
	if body["cell_id"] != e.cellDflt {
		t.Fatalf("строка легла в %v, ожидалась дефолтная ячейка %s", body["cell_id"], e.cellDflt)
	}

	// До оприходования остаток не двигается: черновик для учёта ещё ничего не значит.
	if got := e.stockQty(t, e.cellDflt); got != "0" {
		t.Fatalf("остаток до оприходования: %s, ожидался 0", got)
	}

	code, body = e.do(t, http.MethodPost, "/api/v1/receipts/"+receipt+"/post", "")
	if code != http.StatusOK || body["status"] != model.ReceiptPosted {
		t.Fatalf("оприходование: код %d, тело %+v", code, body)
	}
	if got := e.stockQty(t, e.cellDflt); got != "12.500" {
		t.Fatalf("остаток после оприходования: %s, ожидалось 12.500", got)
	}

	// Повтор оприходования не удваивает приход — это главное, что защищает статус (P4-02).
	if code, _ := e.do(t, http.MethodPost, "/api/v1/receipts/"+receipt+"/post", ""); code != http.StatusConflict {
		t.Fatalf("повтор оприходования: ждали 409, получили %d", code)
	}
	if got := e.stockQty(t, e.cellDflt); got != "12.500" {
		t.Fatalf("остаток после повтора: %s — приход удвоился", got)
	}
}

// Ветка ГЕ: короб заводится по QR ярлыка, строка ссылается на него, после оприходования
// короб размещён и его состав пополнен.
func TestReceiptHTTP_loadUnitBranch(t *testing.T) {
	e := newReceiptE2E(t)
	lu := uuid.NewString()

	if code, body := e.do(t, http.MethodPost, "/api/v1/load-units",
		fmt.Sprintf(`{"load_unit_id":%q,"kind":"box"}`, lu)); code != http.StatusCreated {
		t.Fatalf("завести ГЕ: код %d, тело %+v", code, body)
	}
	// Повтор безопасен: очередь устройства повторяет операцию до подтверждения, а ярлык уже
	// наклеен на короб — второй ГЕ на ту же наклейку быть не должно.
	if code, _ := e.do(t, http.MethodPost, "/api/v1/load-units",
		fmt.Sprintf(`{"load_unit_id":%q,"kind":"box"}`, lu)); code != http.StatusCreated {
		t.Fatalf("повтор заведения ГЕ: код %d", code)
	}

	code, body := e.do(t, http.MethodGet, "/api/v1/load-units/"+lu, "")
	if code != http.StatusOK || body["status"] != model.LoadUnitOpen {
		t.Fatalf("свежая ГЕ: код %d, тело %+v", code, body)
	}

	receipt := uuid.NewString()
	if code, _ := e.do(t, http.MethodPost, "/api/v1/receipts",
		fmt.Sprintf(`{"receipt_id":%q,"warehouse_id":%q}`, receipt, e.warehouse)); code != http.StatusCreated {
		t.Fatalf("создать приёмку: код %d", code)
	}
	line := fmt.Sprintf(`{"good_id":%q,"production_date":"15-01-2026","qty":"6","cell_id":%q,"load_unit_id":%q}`,
		e.good, e.cell, lu)
	if code, body := e.do(t, http.MethodPost, "/api/v1/receipts/"+receipt+"/lines", line); code != http.StatusOK {
		t.Fatalf("строка в ГЕ: код %d, тело %+v", code, body)
	}
	if code, _ := e.do(t, http.MethodPost, "/api/v1/receipts/"+receipt+"/post", ""); code != http.StatusOK {
		t.Fatalf("оприходование ГЕ: код %d", code)
	}

	// Короб уехал в ячейку строки и считается размещённым: отдельного шага размещения у приёмки нет.
	code, body = e.do(t, http.MethodGet, "/api/v1/load-units/"+lu, "")
	if code != http.StatusOK || body["status"] != model.LoadUnitPlaced || body["cell_id"] != e.cell {
		t.Fatalf("ГЕ после оприходования: код %d, тело %+v", code, body)
	}
	var content string
	if err := e.pool.QueryRow(context.Background(),
		`SELECT qty::text FROM lu_content WHERE load_unit_id = $1::uuid`, lu).Scan(&content); err != nil {
		t.Fatalf("состав ГЕ: %v", err)
	}
	if content != "6.000" {
		t.Fatalf("состав ГЕ: %s, ожидалось 6.000", content)
	}
	if got := e.stockQty(t, e.cell); got != "6.000" {
		t.Fatalf("остаток в ячейке ГЕ: %s, ожидалось 6.000", got)
	}
}

// Скан ярлыка, которого система не знает, — рабочая ситуация кладовщика, а не сбой БД:
// он обязан получить внятный 404, а не 500 от нарушения внешнего ключа.
func TestReceiptHTTP_unknownLoadUnitIsNotFound(t *testing.T) {
	e := newReceiptE2E(t)
	receipt := uuid.NewString()
	if code, _ := e.do(t, http.MethodPost, "/api/v1/receipts",
		fmt.Sprintf(`{"receipt_id":%q,"warehouse_id":%q}`, receipt, e.warehouse)); code != http.StatusCreated {
		t.Fatalf("создать приёмку: код %d", code)
	}
	line := fmt.Sprintf(`{"good_id":%q,"production_date":"15-01-2026","qty":"1","load_unit_id":%q}`,
		e.good, uuid.NewString())
	if code, body := e.do(t, http.MethodPost, "/api/v1/receipts/"+receipt+"/lines", line); code != http.StatusNotFound {
		t.Fatalf("незнакомая ГЕ: ждали 404, получили %d, тело %+v", code, body)
	}
}

// Документ показывается кладовщику с именами, а не идентификаторами: он сверяет глазами.
func TestReceiptHTTP_getShowsHumanReadableLines(t *testing.T) {
	e := newReceiptE2E(t)
	receipt := uuid.NewString()
	if code, _ := e.do(t, http.MethodPost, "/api/v1/receipts",
		fmt.Sprintf(`{"receipt_id":%q,"warehouse_id":%q}`, receipt, e.warehouse)); code != http.StatusCreated {
		t.Fatalf("создать приёмку: код %d", code)
	}
	line := fmt.Sprintf(`{"good_id":%q,"production_date":"15-01-2026","qty":"3"}`, e.good)
	if code, _ := e.do(t, http.MethodPost, "/api/v1/receipts/"+receipt+"/lines", line); code != http.StatusOK {
		t.Fatalf("строка приёмки: код %d", code)
	}

	code, body := e.do(t, http.MethodGet, "/api/v1/receipts/"+receipt, "")
	if code != http.StatusOK {
		t.Fatalf("прочитать документ: код %d, тело %+v", code, body)
	}
	if body["status"] != model.ReceiptDraft {
		t.Fatalf("статус документа: %+v", body["status"])
	}
	lines, ok := body["lines"].([]any)
	if !ok || len(lines) != 1 {
		t.Fatalf("строки документа: %+v", body["lines"])
	}
	first := lines[0].(map[string]any)
	if first["good_name"] != "Кальмар" || first["cell_address"] != model.DefaultCellAddress {
		t.Fatalf("строка документа: %+v", first)
	}
	if first["load_unit_id"] != nil {
		t.Fatalf("россыпь не должна ссылаться на ГЕ: %+v", first["load_unit_id"])
	}
}
