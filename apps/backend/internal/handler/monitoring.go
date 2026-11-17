package handler

import (
	"errors"
	"log/slog"
	"net/http"

	chimw "github.com/go-chi/chi/v5/middleware"

	"craftwms/internal/observability"
)

// MonitoringTestMessage - сообщение проверочной ошибки: по нему её находит настройка
// мониторинга (deploy/monitoring-setup.sh) в Bugsink.
const MonitoringTestMessage = "проверка мониторинга"

// errMonitoringTest - сама проверочная ошибка: заголовок события говорит, что сервер в порядке.
var errMonitoringTest = errors.New("тестовая ошибка, её отправил администратор - сервер в порядке")

// MonitoringTest - POST /api/v1/admin/monitoring/test: отправить проверочную ошибку (ADHOC-43).
//
// Что: пишет в журнал запись уровня error - тем же путём, каким идёт любая настоящая ошибка
// (обработчик → slog → Bugsink → письмо), и отвечает, включена ли отправка.
// Зачем: убедиться, что ошибки доходят, не ломая ничего нарочно. Только admin: иначе любой
// с доступом к API мог бы засыпать почту письмами.
func MonitoringTest(w http.ResponseWriter, r *http.Request) {
	slog.ErrorContext(r.Context(), MonitoringTestMessage, "error", errMonitoringTest)
	writeJSON(w, http.StatusOK, map[string]any{
		"reporting":  observability.Enabled(),
		"request_id": chimw.GetReqID(r.Context()),
	})
}
