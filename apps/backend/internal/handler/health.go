// Package handler - HTTP-обработчики (транспортный слой). Разбор запроса, вызов логики,
// сериализация ответа. Бизнес-правил здесь нет.
package handler

import (
	"context"
	"encoding/json"
	"net/http"
	"time"
)

// Pinger - абстракция «чего-то, что умеет проверить свою доступность» (например, пула БД).
// Зачем интерфейс: handler не зависит от конкретного pgx - только от возможности Ping
// (принцип инверсии зависимостей, DIP).
type Pinger interface {
	Ping(ctx context.Context) error
}

// HealthHandler - обработчики проб жизнеспособности и готовности сервиса.
type HealthHandler struct {
	db Pinger // зависимость для readiness; может быть nil, если БД не сконфигурирована
}

// NewHealthHandler создаёт обработчик. db может быть nil (сервис без БД).
func NewHealthHandler(db Pinger) *HealthHandler {
	return &HealthHandler{db: db}
}

// Health - liveness-проба: процесс жив и обслуживает запросы. Всегда 200.
// Её дёргает docker-compose healthcheck (P0-01).
func (h *HealthHandler) Health(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// Ready - readiness-проба: сервис готов работать, т.е. зависимости (БД) доступны.
// Зачем отдельно от Health: БД может отвалиться, а процесс - быть живым; это разные состояния.
func (h *HealthHandler) Ready(w http.ResponseWriter, r *http.Request) {
	if h.db == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "no database configured"})
		return
	}
	// Короткий таймаут - проба не должна зависать.
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := h.db.Ping(ctx); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "database unreachable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

// writeJSON - единый способ отдать JSON-ответ с нужным кодом.
func writeJSON(w http.ResponseWriter, code int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(body)
}
