// Package middleware — общие HTTP-middleware сервиса (логирование, в будущем auth и rate limiting).
package middleware

import (
	"log/slog"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5/middleware"
)

// RequestLogger — middleware структурированного логирования HTTP-запросов.
//
// Что: пишет по одной записи на каждый обработанный запрос.
// Зачем: базовая наблюдаемость и отладка; фундамент будущего журнала операций.
// Как: оборачивает ResponseWriter в chi WrapResponseWriter (чтобы узнать статус и объём ответа),
// замеряет длительность и логирует через slog, добавляя request_id из chi middleware.RequestID.
func RequestLogger(log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ww := middleware.NewWrapResponseWriter(w, r.ProtoMajor)
			start := time.Now()

			next.ServeHTTP(ww, r) // передаём управление дальше по цепочке

			log.Info("http request",
				"method", r.Method,
				"path", r.URL.Path,
				"status", ww.Status(),
				"bytes", ww.BytesWritten(),
				"duration_ms", time.Since(start).Milliseconds(),
				"request_id", middleware.GetReqID(r.Context()),
				"remote", r.RemoteAddr,
			)
		})
	}
}
