// Package handler — HTTP-обработчики (транспортный слой). Разбор запроса, вызов логики,
// сериализация ответа. Бизнес-правил здесь нет.
package handler

import (
	"encoding/json"
	"net/http"
)

// HealthHandler — обработчик liveness-пробы.
//
// Зачем: по /health docker-compose healthcheck (P0-01) и мониторинг понимают, «жив» ли сервис.
// На будущее (P0-03+): сюда добавится проверка доступности БД (ping) — тогда появится
// зависимость на репозиторий, внедряемая через конструктор.
type HealthHandler struct{}

// NewHealthHandler создаёт обработчик health.
func NewHealthHandler() *HealthHandler {
	return &HealthHandler{}
}

// Health отвечает 200 OK и JSON {"status":"ok"} — признак того, что процесс жив и обслуживает запросы.
func (h *HealthHandler) Health(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}
