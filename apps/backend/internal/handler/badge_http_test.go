package handler_test

import (
	"context"
	"net/http"
	"strings"
	"testing"

	"craftwms/internal/auth"
)

// Тестовый ключ номеров бейджей (ADHOC-65): 32 байта шестнадцатерично.
const testBadgeKey = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

// ADHOC-65: «Бейджи» на ТСД через настоящий роутер. Номер запоминается при выдаче в портале и
// при входе по бейджу; уровни прав: свой — только себя, «кроме администратора» — всех, кроме
// «Администратора», «Администратор» — всех. Номер без сохранения — 409, раскрытие — в журнале.
func TestBadgeHTTP_printScopes(t *testing.T) {
	e := newReceivingE2E(t, nil)
	ctx := context.Background()

	// Старший смены — должность с правом «бейджи всех, кроме администратора», бейдж выдан в портале.
	code, raw := e.call(t, http.MethodPost, "/api/v1/positions", e.adminToken,
		`{"name":"Старший смены","rights":["tsd.receipt","tsd.badges.staff"]}`)
	if code != http.StatusCreated {
		t.Fatalf("должность: код %d, %s", code, raw)
	}
	var pos struct {
		ID string `json:"id"`
	}
	mustJSON(t, raw, &pos)
	code, raw = e.call(t, http.MethodPost, "/api/v1/users", e.adminToken,
		`{"full_name":"Старший","position_id":"`+pos.ID+`","badge":"2000000011112222"}`)
	if code != http.StatusCreated {
		t.Fatalf("старший: код %d, %s", code, raw)
	}
	var lead struct {
		ID string `json:"id"`
	}
	mustJSON(t, raw, &lead)
	leadToken := e.login(t, "2000000011112222")

	// Кладовщик заведён до ADHOC-65: хеш есть, номера нет — пока не войдёт.
	hash, err := auth.HashPassword("33334444")
	if err != nil {
		t.Fatalf("хеш: %v", err)
	}
	var worker string
	if err := e.pool.QueryRow(ctx, `UPDATE users SET password_hash = $1 WHERE login = '90000041'
		RETURNING id::text`, hash).Scan(&worker); err != nil {
		t.Fatalf("кладовщик: %v", err)
	}
	var admin string
	if err := e.pool.QueryRow(ctx, `SELECT id::text FROM users WHERE login = '90000042'`).Scan(&admin); err != nil {
		t.Fatalf("администратор: %v", err)
	}

	if code, _ := e.call(t, http.MethodGet, "/api/v1/badges", e.workerToken, ""); code != http.StatusForbidden {
		t.Errorf("кладовщик без права: код %d, ожидался 403", code)
	}
	_, raw = e.call(t, http.MethodGet, "/api/v1/badges", leadToken, "")
	if got := string(raw); !strings.Contains(got, `"id":"`+worker+`","full_name":"Кладовщик","position_name":"Кладовщик","is_admin":false,"stored":false`) ||
		!strings.Contains(got, `"id":"`+lead.ID+`","full_name":"Старший","position_name":"Старший смены","is_admin":false,"stored":true`) ||
		strings.Contains(got, admin) {
		t.Errorf("список старшего: %s", got)
	}
	for id, want := range map[string]int{
		lead.ID: http.StatusOK, worker: http.StatusConflict, admin: http.StatusForbidden,
		"00000000-0000-4000-8000-000000000000": http.StatusNotFound,
	} {
		if code, raw := e.call(t, http.MethodGet, "/api/v1/badges/"+id, leadToken, ""); code != want {
			t.Errorf("старший печатает %s: код %d, ожидался %d (%s)", id, code, want, raw)
		}
	}
	_, raw = e.call(t, http.MethodGet, "/api/v1/badges/"+lead.ID, leadToken, "")
	if !strings.Contains(string(raw), `"full_name":"Старший","badge":"2000000011112222"`) {
		t.Errorf("свой бейдж: %s", raw)
	}

	// Кладовщик вошёл по бейджу — номер запомнился; право «свой» — только себя.
	if code, raw := e.call(t, http.MethodPatch, "/api/v1/positions/7a000000-0000-4000-8000-000000000002", e.adminToken,
		`{"name":"Кладовщик","rights":["tsd.receipt","tsd.badges.own"]}`); code != http.StatusNoContent {
		t.Fatalf("права кладовщика: код %d, %s", code, raw)
	}
	workerToken := e.login(t, "9000004133334444")
	_, raw = e.call(t, http.MethodGet, "/api/v1/badges", workerToken, "")
	if got := string(raw); !strings.HasPrefix(got, `[{"id":"`+worker+`"`) || strings.Count(got, `"id"`) != 1 ||
		!strings.Contains(got, `"stored":true`) {
		t.Errorf("список кладовщика: %s", got)
	}
	if code, _ := e.call(t, http.MethodGet, "/api/v1/badges/"+lead.ID, workerToken, ""); code != http.StatusForbidden {
		t.Errorf("кладовщик печатает чужой: код %d, ожидался 403", code)
	}
	_, raw = e.call(t, http.MethodGet, "/api/v1/badges/"+worker, leadToken, "")
	if !strings.Contains(string(raw), `"badge":"9000004133334444"`) {
		t.Errorf("бейдж кладовщика после входа: %s", raw)
	}

	// Новый бейдж в портале заменяет и номер к печати; «Администратор» печатает всех.
	if code, raw := e.call(t, http.MethodPatch, "/api/v1/users/"+lead.ID, e.adminToken,
		`{"badge":"2000000155556666"}`); code != http.StatusNoContent {
		t.Fatalf("новый бейдж: код %d, %s", code, raw)
	}
	_, raw = e.call(t, http.MethodGet, "/api/v1/badges/"+lead.ID, e.adminToken, "")
	if !strings.Contains(string(raw), `"badge":"2000000155556666"`) {
		t.Errorf("новый бейдж к печати: %s", raw)
	}
	_, raw = e.call(t, http.MethodGet, "/api/v1/badges", e.adminToken, "")
	if !strings.Contains(string(raw), `"id":"`+admin+`","full_name":"Оператор","position_name":"Администратор","is_admin":true,"stored":false`) {
		t.Errorf("список администратора: %s", raw)
	}

	var printed int
	if err := e.pool.QueryRow(ctx, `SELECT count(*) FROM audit_log WHERE action = 'badge.print'`).Scan(&printed); err != nil {
		t.Fatalf("журнал: %v", err)
	}
	if printed != 4 {
		t.Errorf("раскрытий в журнале: %d, ожидалось 4", printed)
	}
}

// login входит по бейджу и возвращает access-токен.
func (e *rcvEnv) login(t *testing.T, badge string) string {
	t.Helper()
	code, raw := e.call(t, http.MethodPost, "/api/v1/auth/login", "", `{"badge":"`+badge+`"}`)
	if code != http.StatusOK {
		t.Fatalf("вход %s: код %d, %s", badge, code, raw)
	}
	var tokens struct {
		Access string `json:"access"`
	}
	mustJSON(t, raw, &tokens)
	return tokens.Access
}
