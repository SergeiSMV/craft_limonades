package handler

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"

	appmw "craftwms/internal/middleware"
	"craftwms/internal/model"
)

// stocktakes — что обработчику нужно от сервиса пересчёта (P10-03).
type stocktakes interface {
	Create(ctx context.Context, in model.StocktakeCreateInput) (model.StocktakeCreated, error)
	Get(ctx context.Context, id, userID string) (model.Stocktake, error)
	Cells(ctx context.Context, stocktakeID, userID string) ([]model.StocktakeCell, error)
	Take(ctx context.Context, id, userID string) error
	Release(ctx context.Context, id, userID string) error
	StartCount(ctx context.Context, stocktakeCellID, userID string) (model.StocktakeCellView, error)
	CellView(ctx context.Context, id, userID string) (model.StocktakeCellView, error)
	Close(ctx context.Context, id, userID string, force bool) (int, error)
	List(ctx context.Context, status string) ([]model.StocktakeListItem, error)
	CountingInCell(ctx context.Context, cellID string) (*model.CellUnderCount, error)
}

// StocktakeHandler — пересчёт склада (P10-03): заведение и закрытие — старшему смены (пока —
// admin), ячейки, взятие и начало подсчёта — работнику на ТСД. Факт ячейки приходит операцией
// очереди stocktake_cell_submit.
type StocktakeHandler struct {
	svc stocktakes
}

// NewStocktakeHandler создаёт обработчик пересчёта.
func NewStocktakeHandler(svc stocktakes) *StocktakeHandler {
	return &StocktakeHandler{svc: svc}
}

type stocktakeCreateRequest struct {
	WarehouseID string   `json:"warehouse_id"`
	ScopeKind   string   `json:"scope_kind"`
	ObjectIDs   []string `json:"object_ids"`
}

type stocktakeCreatedResponse struct {
	ID     string `json:"id"`
	Number int64  `json:"number"`
	TaskID string `json:"task_id"`
	Cells  int    `json:"cells"`
}

type stocktakeCellResponse struct {
	ID          string  `json:"id"`
	StocktakeID string  `json:"stocktake_id"`
	CellID      string  `json:"cell_id"`
	Address     string  `json:"address"`
	Status      string  `json:"status"` // как его видит запросивший: чужая зависшая — pending
	TakenBy     string  `json:"taken_by"`
	TakenAt     *string `json:"taken_at"`   // RFC3339
	StartedAt   *string `json:"started_at"` // RFC3339
	CountedAt   *string `json:"counted_at"` // RFC3339
	Mine        bool    `json:"mine"`
}

// stocktakePositionResponse — позиция снимка без количеств (слепой счёт): короб (load_unit_id)
// ЛИБО россыпь (good …).
type stocktakePositionResponse struct {
	Kind                string            `json:"kind"` // loose | box
	InternalWarehouseID string            `json:"internal_warehouse_id"`
	LoadUnitID          *string           `json:"load_unit_id,omitempty"`
	CZCode              *string           `json:"cz_code,omitempty"`
	Good                *taskGoodResponse `json:"good,omitempty"`
	ProductionDate      *string           `json:"production_date,omitempty"` // DD-MM-YYYY
	Marked              bool              `json:"marked"`
}

type stocktakeCellViewResponse struct {
	stocktakeCellResponse
	Positions []stocktakePositionResponse `json:"positions"`
}

type stocktakeResponse struct {
	ID        string                  `json:"id"`
	Number    int64                   `json:"number"`
	Warehouse string                  `json:"warehouse_id"`
	ScopeKind string                  `json:"scope_kind"`
	Status    string                  `json:"status"`
	TaskID    string                  `json:"task_id"`
	CreatedBy string                  `json:"created_by"`
	CreatedAt string                  `json:"created_at"`
	ClosedAt  *string                 `json:"closed_at"`
	Cells     []stocktakeCellResponse `json:"cells"`
}

func rfc3339(t *time.Time) *string {
	if t == nil {
		return nil
	}
	s := t.Format(time.RFC3339)
	return &s
}

func toStocktakeCell(c model.StocktakeCell) stocktakeCellResponse {
	return stocktakeCellResponse{
		ID: c.ID, StocktakeID: c.StocktakeID, CellID: c.CellID, Address: c.Address, Status: c.Status,
		TakenBy: c.TakenByName, TakenAt: rfc3339(c.TakenAt), StartedAt: rfc3339(c.StartedAt),
		CountedAt: rfc3339(c.CountedAt), Mine: c.Mine,
	}
}

func toStocktakeCellView(v model.StocktakeCellView) stocktakeCellViewResponse {
	out := stocktakeCellViewResponse{stocktakeCellResponse: toStocktakeCell(v.StocktakeCell),
		Positions: make([]stocktakePositionResponse, 0, len(v.Positions))}
	for _, p := range v.Positions {
		pr := stocktakePositionResponse{
			Kind: p.Kind, InternalWarehouseID: p.InternalWarehouseID, LoadUnitID: p.LoadUnitID,
			CZCode: p.CZCode, Marked: p.Marked,
		}
		if p.GoodID != nil {
			pr.Good = &taskGoodResponse{ID: *p.GoodID, Code: p.GoodCode, Name: p.GoodName, Uom: p.Uom}
		}
		if p.ProductionDate != nil {
			d := p.ProductionDate.Format(productionDateLayout)
			pr.ProductionDate = &d
		}
		out.Positions = append(out.Positions, pr)
	}
	return out
}

// Create: POST /api/v1/stocktakes — завести пересчёт по области. 201 — документ, его задание
// и сколько ячеек дала область.
func (h *StocktakeHandler) Create(w http.ResponseWriter, r *http.Request) {
	var req stocktakeCreateRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "тело запроса не JSON")
		return
	}
	userID, _ := appmw.UserIDFromContext(r.Context())
	st, err := h.svc.Create(r.Context(), model.StocktakeCreateInput{
		WarehouseID: req.WarehouseID, ScopeKind: req.ScopeKind, ObjectIDs: req.ObjectIDs, CreatedBy: userID,
	})
	if err != nil {
		stocktakeError(w, r, err, "create")
		return
	}
	writeJSON(w, http.StatusCreated, stocktakeCreatedResponse{ID: st.ID, Number: st.Number, TaskID: st.TaskID, Cells: st.Cells})
}

type stocktakeListItemResponse struct {
	ID        string  `json:"id"`
	Number    int64   `json:"number"`
	ScopeKind string  `json:"scope_kind"`
	Status    string  `json:"status"`
	CreatedBy string  `json:"created_by"`
	CreatedAt string  `json:"created_at"` // RFC3339
	ClosedAt  *string `json:"closed_at"`  // RFC3339
	Cells     int     `json:"cells"`
	Counted   int     `json:"counted"`
}

// List: GET /api/v1/stocktakes?status=open|closed — пересчёты для портала: открытые сверху.
func (h *StocktakeHandler) List(w http.ResponseWriter, r *http.Request) {
	items, err := h.svc.List(r.Context(), r.URL.Query().Get("status"))
	if err != nil {
		stocktakeError(w, r, err, "list")
		return
	}
	out := make([]stocktakeListItemResponse, 0, len(items))
	for _, it := range items {
		out = append(out, stocktakeListItemResponse{
			ID: it.ID, Number: it.Number, ScopeKind: it.ScopeKind, Status: it.Status,
			CreatedBy: it.CreatedByName, CreatedAt: it.CreatedAt.Format(time.RFC3339),
			ClosedAt: rfc3339(it.ClosedAt), Cells: it.Cells, Counted: it.Counted,
		})
	}
	writeJSON(w, http.StatusOK, out)
}

// Get: GET /api/v1/stocktakes/{id} — пересчёт с ходом выполнения: шапка и все ячейки.
func (h *StocktakeHandler) Get(w http.ResponseWriter, r *http.Request) {
	userID, _ := appmw.UserIDFromContext(r.Context())
	st, err := h.svc.Get(r.Context(), chi.URLParam(r, "id"), userID)
	if err != nil {
		stocktakeError(w, r, err, "get")
		return
	}
	out := stocktakeResponse{
		ID: st.ID, Number: st.Number, Warehouse: st.WarehouseID, ScopeKind: st.ScopeKind, Status: st.Status,
		TaskID: st.TaskID, CreatedBy: st.CreatedByName, CreatedAt: st.CreatedAt.Format(time.RFC3339),
		ClosedAt: rfc3339(st.ClosedAt), Cells: make([]stocktakeCellResponse, 0, len(st.Cells)),
	}
	for _, c := range st.Cells {
		out.Cells = append(out.Cells, toStocktakeCell(c))
	}
	writeJSON(w, http.StatusOK, out)
}

// Cells: GET /api/v1/stocktakes/{id}/cells — ячейки, которые работник может считать:
// свободные и свои.
func (h *StocktakeHandler) Cells(w http.ResponseWriter, r *http.Request) {
	userID, _ := appmw.UserIDFromContext(r.Context())
	cells, err := h.svc.Cells(r.Context(), chi.URLParam(r, "id"), userID)
	if err != nil {
		stocktakeError(w, r, err, "cells")
		return
	}
	out := make([]stocktakeCellResponse, 0, len(cells))
	for _, c := range cells {
		out = append(out, toStocktakeCell(c))
	}
	writeJSON(w, http.StatusOK, map[string]any{"cells": out})
}

// Cell: GET /api/v1/stocktake-cells/{id} — своя ячейка с позициями снимка (без количеств).
func (h *StocktakeHandler) Cell(w http.ResponseWriter, r *http.Request) {
	userID, _ := appmw.UserIDFromContext(r.Context())
	v, err := h.svc.CellView(r.Context(), chi.URLParam(r, "id"), userID)
	if err != nil {
		stocktakeError(w, r, err, "cell")
		return
	}
	writeJSON(w, http.StatusOK, toStocktakeCellView(v))
}

// Take: POST /api/v1/stocktake-cells/{id}/take — взять ячейку. 204 / 404 / 409.
func (h *StocktakeHandler) Take(w http.ResponseWriter, r *http.Request) {
	userID, _ := appmw.UserIDFromContext(r.Context())
	if err := h.svc.Take(r.Context(), chi.URLParam(r, "id"), userID); err != nil {
		stocktakeError(w, r, err, "take")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// Release: POST /api/v1/stocktake-cells/{id}/release — отказаться от ячейки; начатый подсчёт
// отбрасывается. 204 / 404 / 409.
func (h *StocktakeHandler) Release(w http.ResponseWriter, r *http.Request) {
	userID, _ := appmw.UserIDFromContext(r.Context())
	if err := h.svc.Release(r.Context(), chi.URLParam(r, "id"), userID); err != nil {
		stocktakeError(w, r, err, "release")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// Start: POST /api/v1/stocktake-cells/{id}/start — скан ячейки на месте: снимок «ожидалось» и
// позиции для слепого счёта. Повтор по начатой ячейке снимок не трогает.
func (h *StocktakeHandler) Start(w http.ResponseWriter, r *http.Request) {
	userID, _ := appmw.UserIDFromContext(r.Context())
	v, err := h.svc.StartCount(r.Context(), chi.URLParam(r, "id"), userID)
	if err != nil {
		stocktakeError(w, r, err, "start")
		return
	}
	writeJSON(w, http.StatusOK, toStocktakeCellView(v))
}

// Close: POST /api/v1/stocktakes/{id}/close — закрыть пересчёт; {"force": true} — досрочно, с
// неподсчитанными ячейками. 200 — сколько ячеек осталось неподсчитанными.
func (h *StocktakeHandler) Close(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Force bool `json:"force"`
	}
	if r.ContentLength != 0 {
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "тело запроса не JSON")
			return
		}
	}
	userID, _ := appmw.UserIDFromContext(r.Context())
	uncounted, err := h.svc.Close(r.Context(), chi.URLParam(r, "id"), userID, req.Force)
	if err != nil {
		stocktakeError(w, r, err, "close")
		return
	}
	writeJSON(w, http.StatusOK, map[string]int{"uncounted": uncounted})
}

// stocktakeCountingResponse — ячейка склада на подсчёте (ADHOC-48).
type stocktakeCountingResponse struct {
	StocktakeNumber int64  `json:"stocktake_number"`
	Address         string `json:"address"`
	CountedBy       string `json:"counted_by"`
	StartedAt       string `json:"started_at"` // RFC3339
}

// CellCounting: GET /api/v1/cells/{id}/stocktake-count — идёт ли в ячейке склада подсчёт
// пересчёта (ADHOC-48). ТСД спрашивает перед движением через ячейку и предупреждает
// кладовщика. 200 — `{"counting": {...}}` или `{"counting": null}`.
func (h *StocktakeHandler) CellCounting(w http.ResponseWriter, r *http.Request) {
	c, err := h.svc.CountingInCell(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		stocktakeError(w, r, err, "cell counting")
		return
	}
	var out *stocktakeCountingResponse
	if c != nil {
		out = &stocktakeCountingResponse{
			StocktakeNumber: c.StocktakeNumber, Address: c.Address, CountedBy: c.CountedByName,
			StartedAt: c.StartedAt.Format(time.RFC3339),
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"counting": out})
}

// stocktakeError — ответ на ошибку пересчёта; текст — для экрана ТСД и портала.
func stocktakeError(w http.ResponseWriter, r *http.Request, err error, action string) {
	switch {
	case errors.Is(err, model.ErrInvalidStocktake):
		writeError(w, http.StatusBadRequest, "пересчёт задан неверно")
	case errors.Is(err, model.ErrStocktakeUnknownObject):
		writeError(w, http.StatusUnprocessableEntity, "объект области не найден или с другого склада")
	case errors.Is(err, model.ErrStocktakeReceivingCell):
		writeError(w, http.StatusUnprocessableEntity, "ячейка приёмки в пересчёт не входит")
	case errors.Is(err, model.ErrStocktakeNoCells):
		writeError(w, http.StatusUnprocessableEntity, "в области нет ни одной ячейки — считать нечего")
	case errors.Is(err, model.ErrStocktakeNotFound):
		writeError(w, http.StatusNotFound, "пересчёт не найден")
	case errors.Is(err, model.ErrStocktakeCellNotFound):
		writeError(w, http.StatusNotFound, "ячейка пересчёта не найдена")
	case errors.Is(err, model.ErrStocktakeClosed):
		writeError(w, http.StatusConflict, "пересчёт уже закрыт")
	case errors.Is(err, model.ErrStocktakeCellBusy):
		writeError(w, http.StatusConflict, "ячейку уже взял другой сотрудник")
	case errors.Is(err, model.ErrStocktakeCellNotYours):
		writeError(w, http.StatusConflict, "ячейка не взята вами — возьмите её в списке")
	case errors.Is(err, model.ErrStocktakeCellCounted):
		writeError(w, http.StatusConflict, "ячейка уже подсчитана")
	case errors.Is(err, model.ErrStocktakeUncounted):
		writeError(w, http.StatusConflict, "не все ячейки подсчитаны — подтвердите досрочное закрытие")
	default:
		slog.ErrorContext(r.Context(), "stocktake action failed", "action", action, "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
	}
}
