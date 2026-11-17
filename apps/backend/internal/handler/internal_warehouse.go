package handler

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"

	"github.com/go-chi/chi/v5"

	"craftwms/internal/model"
)

// internalWarehouses - то, что обработчику справочника внутренних складов нужно от сервиса.
type internalWarehouses interface {
	List(ctx context.Context) ([]model.InternalWarehouse, error)
	Create(ctx context.Context, code, name string) (model.InternalWarehouse, error)
	Update(ctx context.Context, id string, name *string, active, allowPicking *bool) (model.InternalWarehouse, error)
	Delete(ctx context.Context, id string) error
}

// InternalWarehouseHandler - справочник внутренних складов (P6-07-1, ADHOC-29). Читает любой
// сотрудник (ТСД помечает брак и подписывает его), ведёт - только admin из портала.
type InternalWarehouseHandler struct {
	svc internalWarehouses
}

// NewInternalWarehouseHandler создаёт обработчик справочника внутренних складов.
func NewInternalWarehouseHandler(svc internalWarehouses) *InternalWarehouseHandler {
	return &InternalWarehouseHandler{svc: svc}
}

type internalWarehouseResponse struct {
	ID        string `json:"id"`
	Code      string `json:"code"`
	Name      string `json:"name"`
	IsDefault bool   `json:"is_default"`
	IsActive  bool   `json:"is_active"` // скрытый не предлагается для пометки, но подписывается
	InUse     bool   `json:"in_use"`    // есть остаток или история - удалить нельзя, только скрыть
	// Роль системного склада (P6-07-3): не скрыть, не удалить, при пометке не выбрать.
	SystemRole string `json:"system_role,omitempty"`
	// AllowPicking - галочка «разрешить сборку» (P8-02): из товара склада собирают заказы.
	AllowPicking bool `json:"allow_picking"`
}

func toInternalWarehouseResponse(w model.InternalWarehouse) internalWarehouseResponse {
	return internalWarehouseResponse(w)
}

// List: GET /api/v1/internal-warehouses - все склады, и скрытые, по умолчанию первым.
func (h *InternalWarehouseHandler) List(w http.ResponseWriter, r *http.Request) {
	items, err := h.svc.List(r.Context())
	if err != nil {
		slog.ErrorContext(r.Context(), "internal warehouses failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}
	out := make([]internalWarehouseResponse, 0, len(items))
	for _, it := range items {
		out = append(out, toInternalWarehouseResponse(it))
	}
	writeJSON(w, http.StatusOK, out)
}

// Create: POST /api/v1/internal-warehouses {code, name} - завести склад. 201 / 400 / 409.
func (h *InternalWarehouseHandler) Create(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Code string `json:"code"`
		Name string `json:"name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "неверное тело запроса")
		return
	}
	created, err := h.svc.Create(r.Context(), req.Code, req.Name)
	if err != nil {
		internalWarehouseError(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, toInternalWarehouseResponse(created))
}

// Update: PATCH /api/v1/internal-warehouses/{id} {name?, is_active?, allow_picking?} -
// переименовать, скрыть или вернуть в выбор, разрешить или запретить сборку. 200 / 400 / 404 / 409.
func (h *InternalWarehouseHandler) Update(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name         *string `json:"name"`
		IsActive     *bool   `json:"is_active"`
		AllowPicking *bool   `json:"allow_picking"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "неверное тело запроса")
		return
	}
	updated, err := h.svc.Update(r.Context(), chi.URLParam(r, "id"), req.Name, req.IsActive, req.AllowPicking)
	if err != nil {
		internalWarehouseError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, toInternalWarehouseResponse(updated))
}

// Delete: DELETE /api/v1/internal-warehouses/{id} - удалить склад без остатка и истории.
// 204 / 400 / 404 / 409.
func (h *InternalWarehouseHandler) Delete(w http.ResponseWriter, r *http.Request) {
	if err := h.svc.Delete(r.Context(), chi.URLParam(r, "id")); err != nil {
		internalWarehouseError(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// internalWarehouseError - ответ на ошибку ведения справочника; текст - для оператора портала.
func internalWarehouseError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, model.ErrInvalidInternalWarehouse):
		writeError(w, http.StatusBadRequest, "код - латиница, цифры и «_» до 20 знаков; имя - до 100 символов")
	case errors.Is(err, model.ErrUnknownInternalWarehouse):
		writeError(w, http.StatusNotFound, "склад не найден")
	case errors.Is(err, model.ErrInternalWarehouseExists):
		writeError(w, http.StatusConflict, "склад с таким кодом уже есть")
	case errors.Is(err, model.ErrDefaultInternalWarehouse):
		writeError(w, http.StatusConflict, "склад по умолчанию нельзя скрыть или удалить")
	case errors.Is(err, model.ErrSystemInternalWarehouse):
		writeError(w, http.StatusConflict, "системный склад нельзя скрыть, удалить или разрешить к сборке")
	case errors.Is(err, model.ErrInternalWarehouseInUse):
		writeError(w, http.StatusConflict, "на складе есть остаток или история - его можно только скрыть")
	default:
		slog.ErrorContext(r.Context(), "internal warehouse change failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
	}
}
