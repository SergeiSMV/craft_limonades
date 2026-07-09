package handler

import (
	"log/slog"
	"net/http"

	"github.com/go-chi/chi/v5"
	chimw "github.com/go-chi/chi/v5/middleware"

	appmw "craftwms/internal/middleware"
)

// NewRouter собирает HTTP-роутер сервиса: общие middleware + маршруты.
//
// Что: единая точка сборки транспортного слоя.
// Зачем: сюда по мере роста подключаются все будущие ручки (auth, справочники, операции).
// Как: chi-роутер с цепочкой middleware и регистрацией обработчиков.
// db (Pinger) может быть nil — тогда /ready ответит 503.
func NewRouter(log *slog.Logger, db Pinger) http.Handler {
	r := chi.NewRouter()

	// Общие middleware для всех маршрутов:
	r.Use(chimw.RequestID)          // уникальный ID запроса — для трассировки в логах
	r.Use(chimw.Recoverer)          // перехват паник → 500 вместо падения процесса
	r.Use(appmw.RequestLogger(log)) // структурированное логирование каждого запроса

	// Маршруты.
	health := NewHealthHandler(db)
	r.Get("/health", health.Health) // liveness: процесс жив
	r.Get("/ready", health.Ready)   // readiness: БД доступна

	return r
}
