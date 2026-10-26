package handler_test

import (
	"bytes"
	"compress/gzip"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"craftwms/internal/auth"
	"craftwms/internal/handler"
	"craftwms/internal/observability"
)

// Приём событий ТСД и портала (ADHOC-47): путь протокола Sentry через настоящий роутер,
// Bugsink подменён тестовым сервером — тем, что он получил, и проверяется пересылка.

// upstream — подставной Bugsink: запоминает запрос и отвечает заданным кодом.
type upstream struct {
	srv    *httptest.Server
	path   string
	auth   string
	body   string
	status int
	header http.Header
}

func newUpstream(t *testing.T, status int, header http.Header) *upstream {
	t.Helper()
	u := &upstream{status: status, header: header}
	u.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		u.path, u.auth, u.body = r.URL.Path, r.Header.Get("X-Sentry-Auth"), string(raw)
		for k, v := range u.header {
			w.Header()[k] = v
		}
		w.WriteHeader(u.status)
		_, _ = w.Write([]byte(`{"id":"ok"}`))
	}))
	t.Cleanup(u.srv.Close)
	return u
}

// clientRouter — роутер без БД, с пересылкой в [u] (nil — без пересылки).
func clientRouter(t *testing.T, u *upstream) http.Handler {
	t.Helper()
	var svc handler.Services
	if u != nil {
		relay, err := observability.NewRelay("http://realkey@" + strings.TrimPrefix(u.srv.URL, "http://") + "/7")
		if err != nil {
			t.Fatalf("relay: %v", err)
		}
		svc.ClientErrors = relay
	}
	tokens := auth.NewTokenManager("test-secret", time.Hour, time.Hour)
	return handler.NewRouter(slog.New(slog.NewTextHandler(io.Discard, nil)), nil, tokens, svc)
}

// envelope — конверт, каким его шлёт SDK: в заголовке — фиктивный DSN приложения.
const envelope = `{"event_id":"9ec79c33ec9942ab8353589fcb2e04dc","dsn":"https://wms@craft.skogi.ru/1","sdk":{"name":"sentry.dart"}}
{"type":"event","length":41}
{"message":"сбой на ТСД","level":"error"}
`

func postEnvelope(t *testing.T, h http.Handler, path string, body []byte, gz bool) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/x-sentry-envelope")
	if gz {
		req.Header.Set("Content-Encoding", "gzip")
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func gzipped(t *testing.T, s string) []byte {
	t.Helper()
	var b bytes.Buffer
	zw := gzip.NewWriter(&b)
	_, _ = zw.Write([]byte(s))
	_ = zw.Close()
	return b.Bytes()
}

// Сжатый конверт: распакован, фиктивный DSN убран, ключ проекта — в X-Sentry-Auth, адрес —
// проект из CLIENT_SENTRY_DSN; тела элементов дошли как есть.
func TestClientErrors_forwardsWithProjectKey(t *testing.T) {
	u := newUpstream(t, http.StatusOK, nil)
	rec := postEnvelope(t, clientRouter(t, u), "/api/1/envelope/", gzipped(t, envelope), true)

	if rec.Code != http.StatusOK {
		t.Fatalf("код: %d %s", rec.Code, rec.Body)
	}
	if u.path != "/api/7/envelope/" {
		t.Fatalf("путь в Bugsink: %s", u.path)
	}
	if !strings.Contains(u.auth, "sentry_key=realkey") {
		t.Fatalf("ключ проекта не подставлен: %q", u.auth)
	}
	head, rest, _ := strings.Cut(u.body, "\n")
	if strings.Contains(head, "dsn") || !strings.Contains(head, `"event_id"`) {
		t.Fatalf("заголовок конверта: %s", head)
	}
	if rest != strings.SplitN(envelope, "\n", 2)[1] {
		t.Fatalf("элементы конверта изменены: %q", rest)
	}
}

// Перегрузка Bugsink доходит до SDK как есть: код и паузы.
func TestClientErrors_passesRateLimits(t *testing.T) {
	u := newUpstream(t, http.StatusTooManyRequests, http.Header{
		"Retry-After": {"30"}, "X-Sentry-Rate-Limits": {"30:error:organization"},
	})
	rec := postEnvelope(t, clientRouter(t, u), "/api/1/envelope/", []byte(envelope), false)
	if rec.Code != http.StatusTooManyRequests || rec.Header().Get("Retry-After") != "30" ||
		rec.Header().Get("X-Sentry-Rate-Limits") != "30:error:organization" {
		t.Fatalf("ответ: %d %v", rec.Code, rec.Header())
	}
}

// Без пересылки (стенд, локальный стек) — конверт принят и отброшен; чужой проект, не конверт,
// слишком большое тело, недоступный Bugsink — отказ с кодом, по которому SDK не копит ошибки.
func TestClientErrors_refusals(t *testing.T) {
	if rec := postEnvelope(t, clientRouter(t, nil), "/api/1/envelope/", []byte(envelope), false); rec.Code != http.StatusOK {
		t.Fatalf("без пересылки: %d", rec.Code)
	}
	u := newUpstream(t, http.StatusOK, nil)
	h := clientRouter(t, u)
	if rec := postEnvelope(t, h, "/api/2/envelope/", []byte(envelope), false); rec.Code != http.StatusNotFound {
		t.Fatalf("чужой проект: %d", rec.Code)
	}
	if rec := postEnvelope(t, h, "/api/1/envelope/", []byte("не конверт"), false); rec.Code != http.StatusBadRequest {
		t.Fatalf("не конверт: %d", rec.Code)
	}
	big := bytes.Repeat([]byte("x"), 2<<20)
	if rec := postEnvelope(t, h, "/api/1/envelope/", big, false); rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("большое тело: %d", rec.Code)
	}
	bomb := gzipped(t, `{"event_id":"1"}`+"\n"+strings.Repeat("x", 5<<20))
	if rec := postEnvelope(t, h, "/api/1/envelope/", bomb, true); rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("большое после распаковки: %d", rec.Code)
	}
	u.srv.Close()
	rec := postEnvelope(t, h, "/api/1/envelope/", []byte(envelope), false)
	if rec.Code != http.StatusServiceUnavailable || rec.Header().Get("Retry-After") == "" {
		t.Fatalf("Bugsink недоступен: %d %v", rec.Code, rec.Header())
	}
	if u.path != "" {
		t.Fatalf("отказы не должны доходить до Bugsink, дошёл %s", u.path)
	}
}

// Приём событий не задевает прикладной API: /api/v1/… остаётся своим маршрутом.
func TestClientErrors_doesNotShadowAPI(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, "/api/v1/envelope/", strings.NewReader(envelope))
	rec := httptest.NewRecorder()
	clientRouter(t, nil).ServeHTTP(rec, req)
	if rec.Code == http.StatusOK {
		t.Fatalf("/api/v1/envelope/ принят приёмом событий")
	}
}
