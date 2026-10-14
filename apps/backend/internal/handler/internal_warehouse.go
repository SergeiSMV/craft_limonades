package handler

import (
	"log/slog"
	"net/http"

	"craftwms/internal/service"
)

// InternalWarehouseHandler — справочник внутренних складов (P6-07-1). Сотруднику: ТСД
// предлагает выбрать, каким складом пометить короб или товар.
type InternalWarehouseHandler struct {
	svc *service.InternalWarehouseService
}

// NewInternalWarehouseHandler создаёт обработчик справочника внутренних складов.
func NewInternalWarehouseHandler(svc *service.InternalWarehouseService) *InternalWarehouseHandler {
	return &InternalWarehouseHandler{svc: svc}
}

type internalWarehouseResponse struct {
	ID        string `json:"id"`
	Code      string `json:"code"`
	Name      string `json:"name"`
	IsDefault bool   `json:"is_default"`
}

// List: GET /api/v1/internal-warehouses — действующие внутренние склады, по умолчанию первым.
func (h *InternalWarehouseHandler) List(w http.ResponseWriter, r *http.Request) {
	items, err := h.svc.Active(r.Context())
	if err != nil {
		slog.Error("internal warehouses failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}
	out := make([]internalWarehouseResponse, 0, len(items))
	for _, it := range items {
		out = append(out, internalWarehouseResponse(it))
	}
	writeJSON(w, http.StatusOK, out)
}
