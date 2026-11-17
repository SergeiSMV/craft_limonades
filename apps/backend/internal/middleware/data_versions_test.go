package middleware_test

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	appmw "craftwms/internal/middleware"
)

type fakeVersions struct {
	v     map[string]int64
	err   error
	calls int
}

func (f *fakeVersions) DataVersions(context.Context) (map[string]int64, error) {
	f.calls++
	return f.v, f.err
}

// ADHOC-60: версии - в каждом ответе, прочитанные в момент записи ответа (после работы
// обработчика), один раз на ответ; не прочитались - ответ уходит без заголовка.
func TestDataVersionsMiddleware(t *testing.T) {
	serve := func(src *fakeVersions, h http.HandlerFunc) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		appmw.DataVersions(src)(h).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/tasks", nil))
		return rec
	}

	t.Run("версии читаются после работы обработчика", func(t *testing.T) {
		src := &fakeVersions{v: map[string]int64{"tasks": 1}}
		rec := serve(src, func(w http.ResponseWriter, _ *http.Request) {
			src.v = map[string]int64{"tasks": 2, "contents": 7} // операция повысила версии
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write([]byte("{}"))
		})
		if got := rec.Header().Get(appmw.HeaderDataVersions); got != "contents=7,tasks=2" {
			t.Errorf("заголовок = %q", got)
		}
		if src.calls != 1 || rec.Code != http.StatusCreated {
			t.Errorf("чтений %d, код %d", src.calls, rec.Code)
		}
	})

	t.Run("без WriteHeader - заголовок при первой записи", func(t *testing.T) {
		src := &fakeVersions{v: map[string]int64{"goods": 3}}
		rec := serve(src, func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok")) })
		if got := rec.Header().Get(appmw.HeaderDataVersions); got != "goods=3" {
			t.Errorf("заголовок = %q", got)
		}
	})

	t.Run("ошибка чтения - ответ без заголовка", func(t *testing.T) {
		src := &fakeVersions{err: errors.New("нет базы")}
		rec := serve(src, func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) })
		if rec.Code != http.StatusNoContent || rec.Header().Get(appmw.HeaderDataVersions) != "" {
			t.Errorf("код %d, заголовок %q", rec.Code, rec.Header().Get(appmw.HeaderDataVersions))
		}
	})
}
