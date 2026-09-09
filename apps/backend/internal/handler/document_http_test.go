package handler_test

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/shopspring/decimal"

	"craftwms/internal/auth"
	"craftwms/internal/handler"
	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/internal/service"
	"craftwms/internal/testutil"
)

// HTTP-слой документов (P3-02): роль, коды ответов, форма JSON и заголовки файла.
// Сервисный слой покрыт отдельно; здесь проверяется то, что живёт только в транспорте.

type docEnv struct {
	srv         *httptest.Server
	pool        *pgxpool.Pool
	adminToken  string
	workerToken string
	docID       string
}

// newDocE2E поднимает роутер как cmd/server и заводит один закрытый документ.
func newDocE2E(t *testing.T) *docEnv {
	t.Helper()
	pool := testutil.StartPostgres(t)
	ctx := context.Background()
	tokens := auth.NewTokenManager("test-secret", time.Hour, 24*time.Hour)

	seed := func(sql string, args ...any) string {
		var id string
		if err := pool.QueryRow(ctx, sql, args...).Scan(&id); err != nil {
			t.Fatalf("seed %q: %v", sql, err)
		}
		return id
	}
	admin := seed(`INSERT INTO users (login,password_hash,full_name,role)
	               VALUES ('90000010','x','Админ','admin') RETURNING id::text`)
	worker := seed(`INSERT INTO users (login,password_hash,full_name,role)
	                VALUES ('90000011','x','Кладовщик','employee') RETURNING id::text`)
	wh := seed(`INSERT INTO warehouses(code,name) VALUES('SHB','Шабулина') RETURNING id::text`)
	cell := seed(`INSERT INTO cells(warehouse_id,address) VALUES($1::uuid,'M1-1-1-1') RETURNING id::text`, wh)
	good := seed(`INSERT INTO goods(name,uom) VALUES('Кальмар','шт') RETURNING id::text`)

	seRepo := repository.NewStockEntryRepository(pool)
	sid, err := seRepo.Create(ctx, wh, worker)
	if err != nil {
		t.Fatalf("создать сессию: %v", err)
	}
	if err := seRepo.Checkpoint(ctx, sid, cell, []repository.StockEntryLineInput{
		{GoodID: good, ProductionDate: "2026-01-15", Qty: decimal.RequireFromString("3")},
	}, nil); err != nil {
		t.Fatalf("checkpoint: %v", err)
	}
	if _, err := seRepo.Finalize(ctx, sid); err != nil {
		t.Fatalf("финал: %v", err)
	}

	docRepo := repository.NewReportDocumentRepository(pool)
	doc, err := docRepo.BySource(ctx, model.SourceTypeStockEntrySession, sid)
	if err != nil {
		t.Fatalf("документ финала: %v", err)
	}

	adminToken, err := tokens.IssueAccess(admin, string(model.RoleAdmin))
	if err != nil {
		t.Fatalf("токен админа: %v", err)
	}
	workerToken, err := tokens.IssueAccess(worker, string(model.RoleEmployee))
	if err != nil {
		t.Fatalf("токен кладовщика: %v", err)
	}

	router := handler.NewRouter(
		slog.New(slog.NewTextHandler(io.Discard, nil)),
		nil, nil, tokens, nil, nil, nil, nil, nil,
		service.NewDocumentService(docRepo), nil,
	)
	srv := httptest.NewServer(router)
	t.Cleanup(srv.Close)

	return &docEnv{srv: srv, pool: pool, adminToken: adminToken, workerToken: workerToken, docID: doc.ID}
}

// do выполняет запрос с необязательным токеном.
func (e *docEnv) do(t *testing.T, method, path, token string) *http.Response {
	t.Helper()
	req, err := http.NewRequestWithContext(context.Background(), method, e.srv.URL+path, nil)
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do request: %v", err)
	}
	t.Cleanup(func() { _ = resp.Body.Close() })
	return resp
}

// Портал — admin-only: без токена 401, под кладовщиком 403.
func TestDocumentsHTTP_accessControl(t *testing.T) {
	e := newDocE2E(t)
	for _, c := range []struct {
		name, method, path, token string
		want                      int
	}{
		{"список без токена", http.MethodGet, "/api/v1/documents", "", http.StatusUnauthorized},
		{"список под кладовщиком", http.MethodGet, "/api/v1/documents", e.workerToken, http.StatusForbidden},
		{"файл под кладовщиком", http.MethodGet, "/api/v1/documents/" + e.docID + "/file.xlsx", e.workerToken, http.StatusForbidden},
		{"отметка под кладовщиком", http.MethodPost, "/api/v1/documents/" + e.docID + "/done", e.workerToken, http.StatusForbidden},
	} {
		t.Run(c.name, func(t *testing.T) {
			if got := e.do(t, c.method, c.path, c.token).StatusCode; got != c.want {
				t.Errorf("код %d, ожидался %d", got, c.want)
			}
		})
	}
}

// Полный цикл через HTTP: список → файл → «Выполнено» → статус в списке.
func TestDocumentsHTTP_lifecycle(t *testing.T) {
	e := newDocE2E(t)

	list := func() []map[string]any {
		resp := e.do(t, http.MethodGet, "/api/v1/documents", e.adminToken)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("список: код %d", resp.StatusCode)
		}
		var out []map[string]any
		if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
			t.Fatalf("разбор списка: %v", err)
		}
		return out
	}

	docs := list()
	if len(docs) != 1 {
		t.Fatalf("ожидался 1 документ, получено %d", len(docs))
	}
	if docs[0]["status"] != model.DocStatusNew {
		t.Errorf("статус свежего документа: %v", docs[0]["status"])
	}
	if docs[0]["downloaded_at"] != nil || docs[0]["done_at"] != nil {
		t.Errorf("у свежего документа не должно быть отметок: %+v", docs[0])
	}
	if docs[0]["kind"] != model.ReportKindStockEntry {
		t.Errorf("форма документа: %v", docs[0]["kind"])
	}

	// Файл: .xlsx как вложение с осмысленным именем.
	resp := e.do(t, http.MethodGet, "/api/v1/documents/"+e.docID+"/file.xlsx", e.adminToken)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("файл: код %d", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); !strings.Contains(ct, "spreadsheetml") {
		t.Errorf("Content-Type: %q", ct)
	}
	if cd := resp.Header.Get("Content-Disposition"); !strings.Contains(cd, "vvod-ostatkov-SHB-") {
		t.Errorf("Content-Disposition: %q", cd)
	}
	body, _ := io.ReadAll(resp.Body)
	if !strings.HasPrefix(string(body[:2]), "PK") {
		t.Errorf("тело не похоже на .xlsx")
	}

	if docs = list(); docs[0]["status"] != model.DocStatusDownloaded {
		t.Errorf("после скачивания статус: %v", docs[0]["status"])
	}

	// «Выполнено» — 204, повтор тоже 204: двойное нажатие не ошибка.
	for i := 0; i < 2; i++ {
		if got := e.do(t, http.MethodPost, "/api/v1/documents/"+e.docID+"/done", e.adminToken).StatusCode; got != http.StatusNoContent {
			t.Fatalf("отметка (попытка %d): код %d", i+1, got)
		}
	}
	if docs = list(); docs[0]["status"] != model.DocStatusDone || docs[0]["done_at"] == nil {
		t.Errorf("после отметки: %+v", docs[0])
	}
}

// Несуществующий документ — 404 на обеих ручках.
func TestDocumentsHTTP_notFound(t *testing.T) {
	e := newDocE2E(t)
	missing := "00000000-0000-0000-0000-0000000000ff"
	if got := e.do(t, http.MethodGet, "/api/v1/documents/"+missing+"/file.xlsx", e.adminToken).StatusCode; got != http.StatusNotFound {
		t.Errorf("файл: код %d, ожидался 404", got)
	}
	if got := e.do(t, http.MethodPost, "/api/v1/documents/"+missing+"/done", e.adminToken).StatusCode; got != http.StatusNotFound {
		t.Errorf("отметка: код %d, ожидался 404", got)
	}
}
