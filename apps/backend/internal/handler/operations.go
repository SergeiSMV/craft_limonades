package handler

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"

	appmw "craftwms/internal/middleware"
	"craftwms/internal/model"
	"craftwms/internal/service"
)

// OperationsHandler - приём батча операций из очереди устройства (P2-05).
// Доступ - любой аутентифицированный сотрудник: очередь копится на ТСД кладовщика.
type OperationsHandler struct {
	svc *service.OperationsService
}

// NewOperationsHandler создаёт обработчик батча операций.
func NewOperationsHandler(svc *service.OperationsService) *OperationsHandler {
	return &OperationsHandler{svc: svc}
}

// batchRequest - тело POST /operations.
type batchRequest struct {
	Operations []service.Operation `json:"operations"`
}

// batchResponse - исход каждой операции батча.
//
// ⚠ Результатов может быть МЕНЬШЕ, чем прислано операций: разбор прерывается на первой временной
// неудаче, чтобы не нарушить порядок. Устройство снимает с очереди только те, по которым исход
// пришёл, остальные повторит.
type batchResponse struct {
	Results []service.OperationResult `json:"results"`
}

// Apply: POST /api/v1/operations - применить батч операций с дедупом по operation_id.
// 200 {results} / 400 (пустой батч, перебор размера, невалидный JSON) / 500.
func (h *OperationsHandler) Apply(w http.ResponseWriter, r *http.Request) {
	// Автор операций - из токена: старт сессии ввода записывает его в документ, и брать
	// автора из тела значило бы позволить устройству записать проход на другого сотрудника.
	userID, ok := appmw.UserIDFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	var req batchRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "невалидный JSON")
		return
	}

	// Право - по виду операции (ADHOC-50): маршрут пускает любого с правом ТСД.
	access, _ := appmw.AccessFromContext(r.Context())
	results, err := h.svc.ApplyAllowed(r.Context(), userID, req.Operations, func(kind string) bool {
		return access.CanAny(model.OperationRights(kind)...)
	})
	if err != nil {
		switch {
		case errors.Is(err, model.ErrEmptyBatch), errors.Is(err, model.ErrBatchTooLarge):
			writeError(w, http.StatusBadRequest, err.Error())
		default:
			// Временная неудача на ПЕРВОЙ же операции: применить не удалось ничего, и честнее
			// отдать 5xx - устройство повторит весь батч целиком.
			slog.ErrorContext(r.Context(), "operations batch failed", "error", err)
			writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		}
		return
	}
	writeJSON(w, http.StatusOK, batchResponse{Results: results})
}
