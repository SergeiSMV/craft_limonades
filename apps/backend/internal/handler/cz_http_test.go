package handler_test

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"craftwms/internal/auth"
	"craftwms/internal/handler"
	"craftwms/internal/model"
	"craftwms/internal/service"
)

// Тесты CZ-02, шаг 3: ручки admin/cz через роутер, сервис — над подставным клиентом True API.

// czClientStub — клиент True API без сети и подписанта.
type czClientStub struct {
	signerErr error
	infoErr   error
	expiry    time.Time
}

func (c czClientStub) CisesInfo(_ context.Context, codes []string) ([]model.CisInfo, error) {
	if c.infoErr != nil {
		return nil, c.infoErr
	}
	return []model.CisInfo{{
		RequestedCis: codes[0], Cis: codes[0], PackageType: "UNIT", ProducedDate: "2026-10-13",
		Raw: json.RawMessage(`{"cisInfo":{"tnVedEaes":"2202"}}`),
	}}, nil
}
func (c czClientStub) TokenExpiry() (time.Time, bool)     { return c.expiry, !c.expiry.IsZero() }
func (c czClientStub) SignerHealth(context.Context) error { return c.signerErr }

// czRouter — роутер с сервисом ЧЗ и токены админа и кладовщика.
func czRouter(t *testing.T, cz *service.CZService) (http.Handler, string, string) {
	t.Helper()
	tokens := auth.NewTokenManager("test-secret", time.Hour, 24*time.Hour)
	admin, err := tokens.IssueAccess("00000000-0000-4000-8000-0000000000a1", string(model.RoleAdmin))
	if err != nil {
		t.Fatal(err)
	}
	worker, err := tokens.IssueAccess("00000000-0000-4000-8000-0000000000b1", string(model.RoleEmployee))
	if err != nil {
		t.Fatal(err)
	}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	return handler.NewRouter(log, nil, tokens, handler.Services{CZ: cz}), admin, worker
}

func czCall(router http.Handler, token, method, path, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	return rec
}

func TestCZ_adminOnly(t *testing.T) {
	router, _, worker := czRouter(t, service.NewCZService(nil, nil))
	if rec := czCall(router, worker, http.MethodGet, "/api/v1/admin/cz/status", ""); rec.Code != http.StatusForbidden {
		t.Errorf("кладовщик, status: %d, ожидался 403", rec.Code)
	}
	if rec := czCall(router, worker, http.MethodPost, "/api/v1/admin/cz/info", `{"codes":["x"]}`); rec.Code != http.StatusForbidden {
		t.Errorf("кладовщик, info: %d, ожидался 403", rec.Code)
	}
}

func TestCZStatus(t *testing.T) {
	exp := time.Date(2026, 10, 23, 19, 0, 0, 0, time.UTC)
	cases := []struct {
		name string
		svc  *service.CZService
		want string
	}{
		{"not configured", service.NewCZService(nil, nil),
			`{"configured":false,"signer_ok":false,"token_valid":false}`},
		{"ready", service.NewCZService(czClientStub{expiry: exp}, nil),
			`{"configured":true,"signer_ok":true,"token_valid":true,"token_expires_at":"2026-10-23T19:00:00Z"}`},
		{"signer down", service.NewCZService(czClientStub{signerErr: model.ErrCZSignerUnavailable}, nil),
			`{"configured":true,"signer_ok":false,"signer_error":"chestny znak signer unavailable","token_valid":false}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			router, admin, _ := czRouter(t, tc.svc)
			rec := czCall(router, admin, http.MethodGet, "/api/v1/admin/cz/status", "")
			if rec.Code != http.StatusOK || strings.TrimSpace(rec.Body.String()) != tc.want {
				t.Fatalf("got %d %s, want %s", rec.Code, rec.Body, tc.want)
			}
		})
	}
}

func TestCZInfo(t *testing.T) {
	router, admin, _ := czRouter(t, service.NewCZService(czClientStub{}, nil))
	rec := czCall(router, admin, http.MethodPost, "/api/v1/admin/cz/info", `{"codes":["0104600000000017215abc\u001d93tail"]}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("got %d %s", rec.Code, rec.Body)
	}
	var resp struct {
		Items []map[string]any `json:"items"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil || len(resp.Items) != 1 {
		t.Fatalf("body = %s", rec.Body)
	}
	it := resp.Items[0]
	if it["requested_cis"] != "0104600000000017215abc" || it["package_type"] != "UNIT" ||
		it["produced_date"] != "2026-10-13" || it["raw"] == nil {
		t.Fatalf("item = %v", it)
	}
}

func TestCZInfoErrors(t *testing.T) {
	cases := []struct {
		name string
		svc  *service.CZService
		body string
		code int
		msg  string
	}{
		{"bad json", service.NewCZService(czClientStub{}, nil), `codes`, 400, "ожидается"},
		{"no codes", service.NewCZService(czClientStub{}, nil), `{"codes":[" "]}`, 400, "ни одного кода"},
		{"not configured", service.NewCZService(nil, nil), `{"codes":["x"]}`, 503, "не настроен"},
		{"signer down", service.NewCZService(czClientStub{infoErr: model.ErrCZSignerUnavailable}, nil), `{"codes":["x"]}`, 503, "подписант"},
		{"sign-in rejected", service.NewCZService(czClientStub{infoErr: fmt.Errorf("%w: МЧД отозвана", model.ErrCZAuthFailed)}, nil), `{"codes":["x"]}`, 502, "МЧД отозвана"},
		{"api down", service.NewCZService(czClientStub{infoErr: model.ErrCZUnavailable}, nil), `{"codes":["x"]}`, 502, "True API"},
		{"no contract", service.NewCZService(czClientStub{infoErr: fmt.Errorf("%w: water", model.ErrCZNoContract)}, nil), `{"codes":["x"]}`, 422, "договора"},
		{"not found", service.NewCZService(czClientStub{infoErr: model.ErrCZNotFound}, nil), `{"codes":["x"]}`, 404, "не найден"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			router, admin, _ := czRouter(t, tc.svc)
			rec := czCall(router, admin, http.MethodPost, "/api/v1/admin/cz/info", tc.body)
			if rec.Code != tc.code || !strings.Contains(rec.Body.String(), tc.msg) {
				t.Fatalf("got %d %s, want %d with %q", rec.Code, rec.Body, tc.code, tc.msg)
			}
		})
	}
}
