package handler_test

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/google/uuid"

	"craftwms/internal/service"
)

// Фото к проблеме склада (ADHOC-45): загрузка с ТСД, повтор из очереди, предел в три снимка,
// закрытие после решения офиса, отдача снимка и перечень фото в списках проблем.

// jpegBytes — «снимок» JPEG: сервер узнаёт тип по сигнатуре в начале, остальное — содержимое.
func jpegBytes(fill string) []byte {
	return append([]byte{0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 'J', 'F', 'I', 'F', 0x00}, []byte(fill)...)
}

// putPhoto загружает снимок от имени терминала и возвращает код ответа и тело.
func (e *rcvEnv) putPhoto(t *testing.T, problemID, photoID string, body []byte) (int, string) {
	t.Helper()
	req, err := http.NewRequestWithContext(context.Background(), http.MethodPut,
		e.srv.URL+"/api/v1/problems/"+problemID+"/photos/"+photoID, bytes.NewReader(body))
	if err != nil {
		t.Fatalf("запрос: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+e.workerToken)
	req.Header.Set("Content-Type", "image/jpeg")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("PUT фото: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()
	raw, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(raw)
}

// foreignMarkProblem — открытая проблема «чужая марка», заведённая приёмкой (CZ-05).
func foreignMarkProblem(t *testing.T, e *rcvEnv) string {
	t.Helper()
	good := seedCZGood(t, e, "")
	got := e.operations(t, jsonf(`{"operations":[{"operation_id":%q,"kind":"receipt_submit","payload":{
		"receipt_id":%q,"warehouse_id":%q,"doc_number":"ТН-1","doc_date":"01-10-2026",
		"lines":[{"good_id":%q,"production_date":"01-09-2026","qty":1,"marks":[
			{"cis":%q,"discrepancy":"foreign_mark"}]}]}}]}`,
		uuid.NewString(), uuid.NewString(), e.warehouse, good, czMark("P001")))
	if strings.Join(got, ",") != service.StatusAccepted {
		t.Fatalf("приёмка: %v", got)
	}
	return e.scalar(t, `SELECT id::text FROM warehouse_problems`)
}

func TestProblemPhotoHTTP_uploadLimitAndClose(t *testing.T) {
	e := newReceivingE2E(t, nil)
	problem := foreignMarkProblem(t, e)
	first := uuid.NewString()

	if code, body := e.putPhoto(t, problem, first, jpegBytes("один")); code != http.StatusNoContent {
		t.Fatalf("первое фото: %d %s", code, body)
	}
	// Повтор из очереди ТСД (ответ потерялся) — успех без второй записи.
	if code, body := e.putPhoto(t, problem, first, jpegBytes("один")); code != http.StatusNoContent {
		t.Fatalf("повтор: %d %s", code, body)
	}
	for _, fill := range []string{"два", "три"} {
		if code, body := e.putPhoto(t, problem, uuid.NewString(), jpegBytes(fill)); code != http.StatusNoContent {
			t.Fatalf("фото %s: %d %s", fill, code, body)
		}
	}
	if code, _ := e.putPhoto(t, problem, uuid.NewString(), jpegBytes("четыре")); code != http.StatusConflict {
		t.Fatalf("четвёртое фото: код %d, ожидался 409", code)
	}

	// Снимок отдаётся как есть, с типом по содержимому и долгим кэшем.
	req, _ := http.NewRequestWithContext(context.Background(), http.MethodGet,
		e.srv.URL+"/api/v1/problems/"+problem+"/photos/"+first, nil)
	req.Header.Set("Authorization", "Bearer "+e.adminToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET фото: %v", err)
	}
	raw, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK || resp.Header.Get("Content-Type") != "image/jpeg" ||
		!bytes.Equal(raw, jpegBytes("один")) || !strings.Contains(resp.Header.Get("Cache-Control"), "immutable") {
		t.Fatalf("снимок: %d %q %q", resp.StatusCode, resp.Header.Get("Content-Type"), resp.Header.Get("Cache-Control"))
	}

	// Фото — в списках проблем, первым — первое снятое.
	code, body := e.call(t, http.MethodGet, "/api/v1/problems/current", e.workerToken, "")
	var current []struct {
		Photos []string `json:"photos"`
	}
	if code != http.StatusOK || json.Unmarshal(body, &current) != nil || len(current) != 1 ||
		len(current[0].Photos) != 3 || current[0].Photos[0] != first {
		t.Fatalf("фото в «Текущих»: %d %s", code, body)
	}

	// Решение офиса закрывает проблему для новых фото; повтор уже принятого — по-прежнему успех.
	if code, body := e.call(t, http.MethodPost, "/api/v1/problems/"+problem+"/resolve", e.adminToken,
		`{"decision":"place"}`); code != http.StatusNoContent {
		t.Fatalf("решение: %d %s", code, body)
	}
	if code, _ := e.putPhoto(t, problem, uuid.NewString(), jpegBytes("после")); code != http.StatusConflict {
		t.Fatalf("фото к решённой: код %d, ожидался 409", code)
	}
	if code, _ := e.putPhoto(t, problem, first, jpegBytes("один")); code != http.StatusNoContent {
		t.Fatalf("повтор после решения: код %d", code)
	}
}

func TestProblemPhotoHTTP_rejections(t *testing.T) {
	e := newReceivingE2E(t, nil)
	problem := foreignMarkProblem(t, e)
	cases := []struct {
		name           string
		problem, photo string
		body           []byte
		want           int
	}{
		{"проблемы ещё нет на сервере", uuid.NewString(), uuid.NewString(), jpegBytes("x"), http.StatusNotFound},
		{"не снимок", problem, uuid.NewString(), []byte("просто текст"), http.StatusBadRequest},
		{"пустое тело", problem, uuid.NewString(), nil, http.StatusBadRequest},
		{"больше 1 МБ", problem, uuid.NewString(), jpegBytes(strings.Repeat("x", 1<<20)), http.StatusRequestEntityTooLarge},
		{"id фото не UUID", problem, "photo-1", jpegBytes("x"), http.StatusBadRequest},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if code, body := e.putPhoto(t, c.problem, c.photo, c.body); code != c.want {
				t.Fatalf("код %d (%s), ожидался %d", code, body, c.want)
			}
		})
	}
	// Тот же id фото у другой проблемы — конфликт, а не перезапись чужого снимка.
	photo := uuid.NewString()
	if code, _ := e.putPhoto(t, problem, photo, jpegBytes("x")); code != http.StatusNoContent {
		t.Fatalf("фото: %d", code)
	}
	other := foreignMarkProblemAgain(t, e)
	if code, _ := e.putPhoto(t, other, photo, jpegBytes("x")); code != http.StatusConflict {
		t.Fatalf("чужой id фото: код %d, ожидался 409", code)
	}
}

// foreignMarkProblemAgain — вторая проблема той же приёмкой другой марки.
func foreignMarkProblemAgain(t *testing.T, e *rcvEnv) string {
	t.Helper()
	good := e.scalar(t, `SELECT id::text FROM goods LIMIT 1`)
	got := e.operations(t, jsonf(`{"operations":[{"operation_id":%q,"kind":"receipt_submit","payload":{
		"receipt_id":%q,"warehouse_id":%q,"doc_number":"ТН-2","doc_date":"01-10-2026",
		"lines":[{"good_id":%q,"production_date":"01-09-2026","qty":1,"marks":[
			{"cis":%q,"discrepancy":"retired"}]}]}}]}`,
		uuid.NewString(), uuid.NewString(), e.warehouse, good, czMark("P002")))
	if strings.Join(got, ",") != service.StatusAccepted {
		t.Fatalf("приёмка: %v", got)
	}
	return e.scalar(t, `SELECT id::text FROM warehouse_problems WHERE reason = 'retired'`)
}
