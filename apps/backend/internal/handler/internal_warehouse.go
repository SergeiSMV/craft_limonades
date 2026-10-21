package handler

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"

	"github.com/go-chi/chi/v5"

	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/internal/service"
)

// InternalWarehouseHandler — справочник внутренних складов (P6-07-1, ADHOC-29). Читает любой
// сотрудник (ТСД помечает брак и подписывает его), ведёт — только admin из портала.
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
	IsActive  bool   `json:"is_active"` // скрытый не предлагается для пометки, но подписывается
	InUse     bool   `json:"in_use"`    // есть остаток или история — удалить нельзя, только скрыть
}

func toInternalWarehouseResponse(w model.InternalWarehouse) internalWarehouseResponse {
	return internalWarehouseResponse(w)
}

// List: GET /api/v1/internal-warehouses — все склады, и скрытые, по умолчанию первым.
func (h *InternalWarehouseHandler) List(w http.ResponseWriter, r *http.Request) {
	items, err := h.svc.List(r.Context())
	if err != nil {
		slog.Error("internal warehouses failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}
	out := make([]internalWarehouseResponse, 0, len(items))
	for _, it := range items {
		out = append(out, toInternalWarehouseResponse(it))
	}
	writeJSON(w, http.StatusOK, out)
}

// Create: POST /api/v1/internal-warehouses {code, name} — завести склад. 201 / 400 / 409.
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
		internalWarehouseError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, toInternalWarehouseResponse(created))
}

// Update: PATCH /api/v1/internal-warehouses/{id} {name?, is_active?} — переименовать, скрыть
// или вернуть в выбор. 200 / 400 / 404 / 409.
func (h *InternalWarehouseHandler) Update(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name     *string `json:"name"`
		IsActive *bool   `json:"is_active"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "неверное тело запроса")
		return
	}
	updated, err := h.svc.Update(r.Context(), chi.URLParam(r, "id"), req.Name, req.IsActive)
	if err != nil {
		internalWarehouseError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, toInternalWarehouseResponse(updated))
}

// Delete: DELETE /api/v1/internal-warehouses/{id} — удалить склад без остатка и истории.
// 204 / 400 / 404 / 409.
func (h *InternalWarehouseHandler) Delete(w http.ResponseWriter, r *http.Request) {
	if err := h.svc.Delete(r.Context(), chi.URLParam(r, "id")); err != nil {
		internalWarehouseError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// internalWarehouseError — ответ на ошибку ведения справочника; текст — для оператора портала.
func internalWarehouseError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, service.ErrInvalidInternalWarehouse):
		writeError(w, http.StatusBadRequest, "код — латиница, цифры и «_» до 20 знаков; имя — до 100 символов")
	case errors.Is(err, repository.ErrUnknownInternalWarehouse):
		writeError(w, http.StatusNotFound, "склад не найден")
	case errors.Is(err, repository.ErrInternalWarehouseExists):
		writeError(w, http.StatusConflict, "склад с таким кодом уже есть")
	case errors.Is(err, repository.ErrDefaultInternalWarehouse):
		writeError(w, http.StatusConflict, "склад по умолчанию нельзя скрыть или удалить")
	case errors.Is(err, repository.ErrInternalWarehouseInUse):
		writeError(w, http.StatusConflict, "на складе есть остаток или история — его можно только скрыть")
	default:
		slog.Error("internal warehouse change failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
	}
}
