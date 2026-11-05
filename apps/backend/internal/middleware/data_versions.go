package middleware

import (
	"context"
	"log/slog"
	"net/http"
	"sort"
	"strconv"
	"strings"
)

// HeaderDataVersions — заголовок ответа с версиями данных по областям (ADHOC-60):
// «contents=340,goods=12,tasks=88». Клиент перечитывает только области с новой версией.
const HeaderDataVersions = "X-Data-Versions"

// VersionsSource — откуда берутся версии данных (репозиторий data_versions).
type VersionsSource interface {
	DataVersions(ctx context.Context) (map[string]int64, error)
}

// DataVersions — middleware, добавляющий версии данных к каждому ответу API (ADHOC-60).
//
// Что: заголовок X-Data-Versions в каждом ответе — и на чтение, и на операцию.
// Зачем: клиент узнаёт о переменах при обращении, которое и так делает, — без WebSocket и без
// фонового опроса, который сажает батарею ТСД (ADR-0018).
// Как: версии читаются в момент, когда обработчик начинает писать ответ, — после фиксации его
// транзакции. Поэтому ответ на свою операцию уже несёт версию после неё, и клиент не станет
// перечитывать то, что сделал сам. Версии не прочитались — ответ уходит без заголовка: клиент
// просто ничего не перечитает, а сам запрос ломать из-за этого нельзя.
func DataVersions(src VersionsSource) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			next.ServeHTTP(&versionsWriter{ResponseWriter: w, ctx: r.Context(), src: src}, r)
		})
	}
}

// versionsWriter ставит заголовок версий перед первой записью ответа.
type versionsWriter struct {
	http.ResponseWriter
	ctx     context.Context
	src     VersionsSource
	written bool
}

func (w *versionsWriter) WriteHeader(code int) {
	w.setVersions()
	w.ResponseWriter.WriteHeader(code)
}

func (w *versionsWriter) Write(b []byte) (int, error) {
	w.setVersions()
	return w.ResponseWriter.Write(b)
}

// Unwrap даёт http.ResponseController добраться до исходного writer (Flush, дедлайны).
func (w *versionsWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func (w *versionsWriter) setVersions() {
	if w.written {
		return
	}
	w.written = true
	versions, err := w.src.DataVersions(w.ctx)
	if err != nil {
		slog.WarnContext(w.ctx, "data versions unavailable", "error", err)
		return
	}
	w.Header().Set(HeaderDataVersions, FormatDataVersions(versions))
}

// FormatDataVersions — версии в виде заголовка: области по алфавиту, «область=версия» через
// запятую. Порядок постоянный — заголовок легко сравнивать глазами и в тестах.
func FormatDataVersions(versions map[string]int64) string {
	domains := make([]string, 0, len(versions))
	for d := range versions {
		domains = append(domains, d)
	}
	sort.Strings(domains)
	parts := make([]string, 0, len(domains))
	for _, d := range domains {
		parts = append(parts, d+"="+strconv.FormatInt(versions[d], 10))
	}
	return strings.Join(parts, ",")
}
