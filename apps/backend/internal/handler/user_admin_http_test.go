package handler_test

import (
	"net/http"
	"strings"
	"testing"

	"craftwms/internal/model"
)

// ADHOC-49: должности и права через настоящий роутер. Админ заводит должность «Оператор» с
// правами «портал» и «проблемы склада» и пользователя на ней с входом по паролю; оператор
// видит проблемы, но не документы и не ручки ТСД. Новое право действует сразу, без нового
// токена; блокировка — тоже. Кладовщику пользователи недоступны.
func TestUserAdminHTTP_positionRights(t *testing.T) {
	e := newReceivingE2E(t, nil)

	if code, _ := e.call(t, http.MethodGet, "/api/v1/positions", e.workerToken, ""); code != http.StatusForbidden {
		t.Errorf("кладовщик смотрит должности: код %d, ожидался 403", code)
	}
	_, raw := e.call(t, http.MethodGet, "/api/v1/rights", e.adminToken, "")
	if string(raw) != `{"rights":["tsd","portal","catalog","documents","problems","stocktake","warehouses","cz","users"]}`+"\n" {
		t.Errorf("права: %s", raw)
	}

	code, raw := e.call(t, http.MethodPost, "/api/v1/positions", e.adminToken,
		`{"name":"  Оператор ","rights":["problems","portal","problems"]}`)
	if code != http.StatusCreated {
		t.Fatalf("завести должность: код %d, %s", code, raw)
	}
	var pos struct {
		ID string `json:"id"`
	}
	mustJSON(t, raw, &pos)
	_, raw = e.call(t, http.MethodGet, "/api/v1/positions", e.adminToken, "")
	if !strings.Contains(string(raw), `"name":"Оператор","rights":["portal","problems"],"is_system":false,"users":0`) ||
		!strings.HasPrefix(string(raw), `[{"id":"`+model.PositionAdminID+`","name":"Администратор"`) {
		t.Errorf("должности: %s", raw)
	}
	if code, _ := e.call(t, http.MethodPost, "/api/v1/positions", e.adminToken, `{"name":"Склад","rights":["fly"]}`); code != http.StatusBadRequest {
		t.Errorf("неизвестное право: код %d, ожидался 400", code)
	}

	code, raw = e.call(t, http.MethodPost, "/api/v1/users", e.adminToken,
		`{"full_name":"Офис  Оператор","position_id":"`+pos.ID+`","username":"office","password":"secret-pass"}`)
	if code != http.StatusCreated {
		t.Fatalf("завести пользователя: код %d, %s", code, raw)
	}
	var user struct {
		ID string `json:"id"`
	}
	mustJSON(t, raw, &user)
	code, raw = e.call(t, http.MethodPost, "/api/v1/auth/login/password", "", `{"username":"office","password":"secret-pass"}`)
	if code != http.StatusOK {
		t.Fatalf("вход оператора: код %d, %s", code, raw)
	}
	var tokens struct {
		Access string `json:"access"`
	}
	mustJSON(t, raw, &tokens)
	op := tokens.Access

	_, raw = e.call(t, http.MethodGet, "/api/v1/auth/me", op, "")
	if !strings.Contains(string(raw), `"full_name":"Офис Оператор","role":"employee","position":"Оператор","rights":["portal","problems"]`) {
		t.Errorf("профиль оператора: %s", raw)
	}
	for path, want := range map[string]int{
		"/api/v1/problems":            http.StatusOK,
		"/api/v1/documents":           http.StatusForbidden,
		"/api/v1/tasks":               http.StatusForbidden, // ручка ТСД
		"/api/v1/internal-warehouses": http.StatusOK,        // справочники читает любой вошедший
	} {
		if code, _ := e.call(t, http.MethodGet, path, op, ""); code != want {
			t.Errorf("оператор %s: код %d, ожидался %d", path, code, want)
		}
	}

	if code, raw := e.call(t, http.MethodPatch, "/api/v1/positions/"+pos.ID, e.adminToken,
		`{"name":"Оператор","rights":["portal","problems","documents"]}`); code != http.StatusNoContent {
		t.Fatalf("дать право документов: код %d, %s", code, raw)
	}
	if code, _ := e.call(t, http.MethodGet, "/api/v1/documents", op, ""); code != http.StatusOK {
		t.Errorf("документы после нового права — с прежним токеном: код %d, ожидался 200", code)
	}

	if code, raw := e.call(t, http.MethodPatch, "/api/v1/users/"+user.ID, e.adminToken, `{"is_active":false}`); code != http.StatusNoContent {
		t.Fatalf("заблокировать: код %d, %s", code, raw)
	}
	if code, _ := e.call(t, http.MethodGet, "/api/v1/problems", op, ""); code != http.StatusUnauthorized {
		t.Errorf("заблокированный с прежним токеном: код %d, ожидался 401", code)
	}
	if code, _ := e.call(t, http.MethodDelete, "/api/v1/positions/"+pos.ID, e.adminToken, ""); code != http.StatusConflict {
		t.Errorf("удалить должность с пользователем: код %d, ожидался 409", code)
	}

	var actions string
	if err := e.pool.QueryRow(t.Context(), `SELECT string_agg(action, ',' ORDER BY id) FROM audit_log
		WHERE action LIKE 'user.%' OR action LIKE 'position.%'`).Scan(&actions); err != nil ||
		actions != "position.create,user.create,position.update,user.update" {
		t.Errorf("журнал правок: %q, %v", actions, err)
	}
	var leaked bool
	if err := e.pool.QueryRow(t.Context(), `SELECT EXISTS (SELECT 1 FROM audit_log WHERE details::text LIKE '%secret-pass%'
		OR details::text LIKE '%argon2%')`).Scan(&leaked); err != nil || leaked {
		t.Errorf("пароль или хеш в журнале: %v %v", leaked, err)
	}
}

// ADHOC-49: бейдж нового работника — вход как у всех; занятый бейдж, второй способ входа и
// чужой способ правки — отказ. Систему нельзя оставить без управления: системную должность не
// изменить и не удалить, единственного администратора не перевести и не заблокировать, себя —
// тоже.
func TestUserAdminHTTP_guards(t *testing.T) {
	e := newReceivingE2E(t, nil)
	admin := e.scalar(t, `SELECT id::text FROM users WHERE full_name = 'Оператор'`)

	const badge = "5500000112345678"
	code, raw := e.call(t, http.MethodPost, "/api/v1/users", e.adminToken,
		`{"full_name":"Новый кладовщик","position_id":"`+model.PositionWorkerID+`","badge":"`+badge+`"}`)
	if code != http.StatusCreated {
		t.Fatalf("завести по бейджу: код %d, %s", code, raw)
	}
	var worker struct {
		ID string `json:"id"`
	}
	mustJSON(t, raw, &worker)
	if code, raw := e.call(t, http.MethodPost, "/api/v1/auth/login", "", `{"badge":"`+badge+`"}`); code != http.StatusOK {
		t.Errorf("вход по новому бейджу: код %d, %s", code, raw)
	}
	_, raw = e.call(t, http.MethodGet, "/api/v1/users", e.adminToken, "")
	if !strings.Contains(string(raw), `"full_name":"Новый кладовщик","position_id":"`+model.PositionWorkerID+
		`","position_name":"Кладовщик","login":"55000001","is_active":true`) || strings.Contains(string(raw), "12345678") {
		t.Errorf("список пользователей: %s", raw)
	}

	for _, c := range []struct {
		what, method, path, body string
		want                     int
	}{
		{"бейдж занят", http.MethodPost, "/api/v1/users",
			`{"full_name":"Двойник","position_id":"` + model.PositionWorkerID + `","badge":"5500000187654321"}`, http.StatusConflict},
		{"два способа входа", http.MethodPost, "/api/v1/users",
			`{"full_name":"Двойник","position_id":"` + model.PositionWorkerID + `","badge":"5500000287654321","username":"twin","password":"12345678"}`, http.StatusBadRequest},
		{"короткий пароль", http.MethodPost, "/api/v1/users",
			`{"full_name":"Офис","position_id":"` + model.PositionWorkerID + `","username":"office2","password":"123"}`, http.StatusBadRequest},
		{"пароль работнику по бейджу", http.MethodPatch, "/api/v1/users/" + worker.ID, `{"password":"12345678"}`, http.StatusBadRequest},
		{"системную должность изменить", http.MethodPatch, "/api/v1/positions/" + model.PositionAdminID,
			`{"name":"Босс","rights":["portal"]}`, http.StatusConflict},
		{"системную должность удалить", http.MethodDelete, "/api/v1/positions/" + model.PositionAdminID, "", http.StatusConflict},
		{"единственного админа — в кладовщики", http.MethodPatch, "/api/v1/users/" + admin,
			`{"position_id":"` + model.PositionWorkerID + `"}`, http.StatusConflict},
		{"себя заблокировать", http.MethodPatch, "/api/v1/users/" + admin, `{"is_active":false}`, http.StatusConflict},
		{"нет такого", http.MethodPatch, "/api/v1/users/7f000000-0000-4000-8000-000000000999", `{"full_name":"Х"}`, http.StatusNotFound},
	} {
		if code, raw := e.call(t, c.method, c.path, e.adminToken, c.body); code != c.want {
			t.Errorf("%s: код %d, ожидался %d (%s)", c.what, code, c.want, raw)
		}
	}

	// Новый бейдж взамен утерянного: прежний больше не входит, новый — входит.
	const newBadge = "5500000999999999"
	if code, raw := e.call(t, http.MethodPatch, "/api/v1/users/"+worker.ID, e.adminToken, `{"badge":"`+newBadge+`"}`); code != http.StatusNoContent {
		t.Fatalf("новый бейдж: код %d, %s", code, raw)
	}
	if code, _ := e.call(t, http.MethodPost, "/api/v1/auth/login", "", `{"badge":"`+badge+`"}`); code != http.StatusUnauthorized {
		t.Errorf("вход по прежнему бейджу: код %d, ожидался 401", code)
	}
	if code, _ := e.call(t, http.MethodPost, "/api/v1/auth/login", "", `{"badge":"`+newBadge+`"}`); code != http.StatusOK {
		t.Errorf("вход по новому бейджу: код %d", code)
	}

	// Второй администратор появился — первого уже можно перевести.
	if code, raw := e.call(t, http.MethodPatch, "/api/v1/users/"+worker.ID, e.adminToken,
		`{"position_id":"`+model.PositionAdminID+`"}`); code != http.StatusNoContent {
		t.Fatalf("второй админ: код %d, %s", code, raw)
	}
	if code, raw := e.call(t, http.MethodPatch, "/api/v1/users/"+admin, e.adminToken,
		`{"position_id":"`+model.PositionWorkerID+`"}`); code != http.StatusNoContent {
		t.Errorf("перевести админа при втором: код %d, %s", code, raw)
	}
}
