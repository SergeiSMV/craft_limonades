package observability

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/getsentry/sentry-go"
	chimw "github.com/go-chi/chi/v5/middleware"
)

// Тесты ADHOC-42: что уходит в Bugsink и с чем.

// memTransport - перехват событий вместо отправки по сети.
type memTransport struct {
	mu     sync.Mutex
	events []*sentry.Event
}

func (t *memTransport) Configure(sentry.ClientOptions)        {}
func (t *memTransport) Flush(time.Duration) bool              { return true }
func (t *memTransport) FlushWithContext(context.Context) bool { return true }
func (t *memTransport) Close()                                {}
func (t *memTransport) SendEvent(e *sentry.Event) {
	t.mu.Lock()
	t.events = append(t.events, e)
	t.mu.Unlock()
}
func (t *memTransport) all() []*sentry.Event {
	t.mu.Lock()
	defer t.mu.Unlock()
	return append([]*sentry.Event(nil), t.events...)
}

// enable включает отправку в память и выключает её после теста: hub общий на процесс.
func enable(t *testing.T) *memTransport {
	t.Helper()
	tr := &memTransport{}
	ok, err := Init(Options{DSN: "http://key@bugsink.local/1", Environment: "test", Transport: tr})
	if err != nil || !ok {
		t.Fatalf("Init: %v %v", ok, err)
	}
	t.Cleanup(func() {
		sentry.CurrentHub().BindClient(nil)
		active.Store(false)
	})
	return tr
}

type ctxKey struct{}

// testUser - пользователь из контекста, как его кладёт middleware аутентификации.
func testUser(ctx context.Context) (string, string, bool) {
	id, ok := ctx.Value(ctxKey{}).(string)
	return id, "employee", ok
}

func newTestLogger(buf *bytes.Buffer) *slog.Logger {
	return slog.New(NewHandler(slog.NewJSONHandler(buf, nil), testUser))
}

func TestHandler_errorBecomesEvent_infoDoesNot(t *testing.T) {
	tr := enable(t)
	var buf bytes.Buffer
	log := newTestLogger(&buf).With("component", "documents")

	ctx := context.WithValue(context.Background(), ctxKey{}, "user-7")
	log.InfoContext(ctx, "documents listed", "count", 3)
	log.ErrorContext(ctx, "documents list failed", "error", fmt.Errorf("query: %w", errors.New("connection reset")), "document", "d1")

	events := tr.all()
	if len(events) != 1 {
		t.Fatalf("событий %d, ожидалось одно - только ошибка", len(events))
	}
	e := events[0]
	if e.Message != "documents list failed" || e.Level != sentry.LevelError {
		t.Errorf("сообщение %q уровень %q", e.Message, e.Level)
	}
	if e.User.ID != "user-7" || e.Tags["role"] != "employee" {
		t.Errorf("пользователь %+v теги %v", e.User, e.Tags)
	}
	if len(e.Exception) == 0 || !strings.Contains(e.Exception[len(e.Exception)-1].Value, "connection reset") {
		t.Errorf("ошибка не попала в исключение: %+v", e.Exception)
	}
	fields := e.Contexts["log"]
	if fields["component"] != "documents" || fields["document"] != "d1" {
		t.Errorf("атрибуты записи: %v", fields)
	}
	if !strings.Contains(buf.String(), "documents list failed") || !strings.Contains(buf.String(), "documents listed") {
		t.Error("журнал должен писаться как раньше")
	}
}

func TestHandler_disabledSendsNothing(t *testing.T) {
	sentry.CurrentHub().BindClient(nil)
	active.Store(false)
	if ok, err := Init(Options{}); ok || err != nil {
		t.Fatalf("без DSN отправка должна быть выключена: %v %v", ok, err)
	}
	var buf bytes.Buffer
	newTestLogger(&buf).Error("boom")
	if !strings.Contains(buf.String(), "boom") {
		t.Error("журнал должен писаться и без Bugsink")
	}
}

// Паника уходит событием с запросом и request_id, а дальше её получает Recoverer (ответ 500).
// Токен из заголовка авторизации в событие не попадает.
func TestMiddleware_panicCapturedAndRethrown(t *testing.T) {
	tr := enable(t)
	h := chimw.RequestID(chimw.Recoverer(Middleware(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		panic("nil map")
	}))))
	req := httptest.NewRequest(http.MethodPost, "/api/v1/operations", nil)
	req.Header.Set("Authorization", "Bearer secret-token")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Errorf("код %d, Recoverer должен был ответить 500", rec.Code)
	}
	events := tr.all()
	if len(events) != 1 {
		t.Fatalf("событий %d, ожидалось одно", len(events))
	}
	e := events[0]
	if e.Tags["request_id"] == "" {
		t.Error("нет request_id - событие не сопоставить с журналом")
	}
	if e.Request == nil || !strings.HasSuffix(e.Request.URL, "/api/v1/operations") {
		t.Errorf("запрос в событии: %+v", e.Request)
	}
	// SDK оставляет заголовок, но значение заменяет на «[Filtered]».
	for k, v := range e.Request.Headers {
		if strings.Contains(v, "secret-token") {
			t.Errorf("токен попал в событие: %s=%s", k, v)
		}
	}
}

// Ошибка журнала внутри запроса едет с запросом этого запроса - через hub из контекста.
func TestMiddleware_errorLogCarriesRequest(t *testing.T) {
	tr := enable(t)
	var buf bytes.Buffer
	log := newTestLogger(&buf)
	h := chimw.RequestID(Middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.ErrorContext(r.Context(), "receipt submit failed", "error", errors.New("deadlock detected"))
		w.WriteHeader(http.StatusInternalServerError)
	})))
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/api/v1/tasks", nil))

	events := tr.all()
	if len(events) != 1 || events[0].Request == nil || events[0].Tags["request_id"] == "" {
		t.Fatalf("событие без запроса: %+v", events)
	}
}

// Без Init отправка выключена, даже если у hub есть клиент-заглушка sentry-go.
func TestEnabled_falseWithoutInit(t *testing.T) {
	active.Store(false)
	if Enabled() {
		t.Error("без Init с DSN отправка должна считаться выключенной")
	}
}
