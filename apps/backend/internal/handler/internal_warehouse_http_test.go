package handler_test

import (
	"encoding/json"
	"net/http"
	"testing"
)

// ADHOC-29: справочник внутренних складов через настоящий роутер. Читает любой сотрудник
// (и скрытые — ТСД подписывает их остаток), ведёт только admin.
func TestInternalWarehousesHTTP_adminManages(t *testing.T) {
	e := newReceivingE2E(t, nil)

	if code, _ := e.call(t, http.MethodPost, "/api/v1/internal-warehouses", e.workerToken,
		`{"code":"RECALL","name":"Возврат"}`); code != http.StatusForbidden {
		t.Fatalf("кладовщик заводит склад: %d", code)
	}

	code, body := e.call(t, http.MethodPost, "/api/v1/internal-warehouses", e.adminToken,
		`{"code":"recall","name":"Возврат"}`)
	var created struct {
		ID       string `json:"id"`
		Code     string `json:"code"`
		IsActive bool   `json:"is_active"`
	}
	if code != http.StatusCreated || json.Unmarshal(body, &created) != nil || created.Code != "RECALL" || !created.IsActive {
		t.Fatalf("завести: %d %s", code, body)
	}
	if code, _ := e.call(t, http.MethodPost, "/api/v1/internal-warehouses", e.adminToken,
		`{"code":"RECALL","name":"Повтор"}`); code != http.StatusConflict {
		t.Errorf("повтор кода: %d", code)
	}
	if code, _ := e.call(t, http.MethodPost, "/api/v1/internal-warehouses", e.adminToken,
		`{"code":"С ПРОБЕЛОМ","name":"Склад"}`); code != http.StatusBadRequest {
		t.Errorf("кривой код: %d", code)
	}

	if code, body := e.call(t, http.MethodPatch, "/api/v1/internal-warehouses/"+created.ID, e.adminToken,
		`{"is_active":false}`); code != http.StatusOK {
		t.Errorf("скрыть: %d %s", code, body)
	}

	// Скрытый остаётся в справочнике для ТСД — с признаком.
	code, body = e.call(t, http.MethodGet, "/api/v1/internal-warehouses", e.workerToken, "")
	var list []struct {
		ID        string `json:"id"`
		IsDefault bool   `json:"is_default"`
		IsActive  bool   `json:"is_active"`
		InUse     bool   `json:"in_use"`
	}
	if code != http.StatusOK || json.Unmarshal(body, &list) != nil || !list[0].IsDefault {
		t.Fatalf("список: %d %s", code, body)
	}
	found := false
	for _, w := range list {
		if w.ID == created.ID {
			found = !w.IsActive && !w.InUse
		}
	}
	if !found {
		t.Errorf("скрытый склад в списке: %s", body)
	}

	if code, _ := e.call(t, http.MethodPatch, "/api/v1/internal-warehouses/"+list[0].ID, e.adminToken,
		`{"is_active":false}`); code != http.StatusConflict {
		t.Errorf("скрыть склад по умолчанию: %d", code)
	}
	if code, _ := e.call(t, http.MethodDelete, "/api/v1/internal-warehouses/"+created.ID, e.adminToken, ""); code != http.StatusNoContent {
		t.Errorf("удалить свободный склад: %d", code)
	}
	if code, _ := e.call(t, http.MethodDelete, "/api/v1/internal-warehouses/"+created.ID, e.adminToken, ""); code != http.StatusNotFound {
		t.Errorf("удалить ещё раз: %d", code)
	}
}
