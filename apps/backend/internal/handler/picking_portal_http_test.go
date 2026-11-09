package handler_test

import (
	"io"
	"log/slog"
	"net/http"
	"testing"
	"time"

	"craftwms/internal/auth"
	"craftwms/internal/handler"
	"craftwms/internal/model"
	"craftwms/internal/service"
)

// P8-03: ручки «Сборка-отгрузка» портала через роутер — кладовщику без прав портала 403 на
// каждую; без даты накладной — 400 до похода в базу. Данные — в TestPickingPortal_live.
func TestPickingPortalHTTP_rights(t *testing.T) {
	tokens := auth.NewTokenManager("test-secret", time.Hour, 24*time.Hour)
	admin, err := tokens.IssueAccess("00000000-0000-4000-8000-0000000000a1", string(model.RoleAdmin))
	if err != nil {
		t.Fatal(err)
	}
	worker, err := tokens.IssueAccess("00000000-0000-4000-8000-0000000000b1", string(model.RoleEmployee))
	if err != nil {
		t.Fatal(err)
	}
	router := handler.NewRouter(slog.New(slog.NewTextHandler(io.Discard, nil)), nil, tokens,
		handler.Services{PickingPortal: service.NewPickingPortalService(nil, nil), Rights: testRights})
	for _, c := range []struct{ method, path string }{
		{http.MethodGet, "/api/v1/picking/portal/orders?date=2026-11-09"},
		{http.MethodGet, "/api/v1/picking/portal/orders/22222222-2222-4222-8222-222222222222"},
		{http.MethodPost, "/api/v1/picking/portal/orders/22222222-2222-4222-8222-222222222222/release"},
		{http.MethodGet, "/api/v1/picking/portal/export.xlsx?date=2026-11-09"},
	} {
		if rec := czCall(router, worker, c.method, c.path, ""); rec.Code != http.StatusForbidden {
			t.Errorf("кладовщик %s %s: %d, ждали 403", c.method, c.path, rec.Code)
		}
	}
	// ADHOC-62: карточка заказа на ТСД - только с правом сборки.
	if rec := czCall(router, worker, http.MethodGet,
		"/api/v1/picking/orders/22222222-2222-4222-8222-222222222222/card", ""); rec.Code != http.StatusForbidden {
		t.Errorf("кладовщик без tsd.picking, карточка: %d, ждали 403", rec.Code)
	}
	for _, path := range []string{
		"/api/v1/picking/portal/orders",
		"/api/v1/picking/portal/orders?date=09.11.2026",
		"/api/v1/picking/portal/export.xlsx",
	} {
		if rec := czCall(router, admin, http.MethodGet, path, ""); rec.Code != http.StatusBadRequest {
			t.Errorf("без даты %s: %d, ждали 400", path, rec.Code)
		}
	}
}
