package handler_test

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"craftwms/internal/auth"
	"craftwms/internal/handler"
	"craftwms/internal/model"
)

// Проверка мониторинга (ADHOC-43): проверочная ошибка — только админу. Без Bugsink (тесты)
// ответ честно говорит, что отправка выключена, а запись в журнал всё равно есть.
func TestMonitoringTest_adminOnly(t *testing.T) {
	tokens := auth.NewTokenManager("test-secret", time.Hour, 24*time.Hour)
	admin, err := tokens.IssueAccess("00000000-0000-4000-8000-0000000000a1", string(model.RoleAdmin))
	if err != nil {
		t.Fatal(err)
	}
	worker, err := tokens.IssueAccess("00000000-0000-4000-8000-0000000000b1", string(model.RoleEmployee))
	if err != nil {
		t.Fatal(err)
	}
	router := handler.NewRouter(slog.New(slog.NewTextHandler(io.Discard, nil)), nil, tokens, handler.Services{Rights: testRights})

	call := func(token string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/api/v1/admin/monitoring/test", nil)
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		rec := httptest.NewRecorder()
		router.ServeHTTP(rec, req)
		return rec
	}

	if code := call("").Code; code != http.StatusUnauthorized {
		t.Errorf("без токена: %d, ожидался 401", code)
	}
	if code := call(worker).Code; code != http.StatusForbidden {
		t.Errorf("кладовщик: %d, ожидался 403", code)
	}
	rec := call(admin)
	if rec.Code != http.StatusOK {
		t.Fatalf("админ: %d %s", rec.Code, rec.Body)
	}
	var body struct {
		Reporting bool   `json:"reporting"`
		RequestID string `json:"request_id"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.Reporting || body.RequestID == "" {
		t.Errorf("ответ: %+v — без DSN отправка выключена, request_id обязателен", body)
	}
}
