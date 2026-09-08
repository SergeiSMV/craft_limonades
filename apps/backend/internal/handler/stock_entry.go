package handler

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/shopspring/decimal"

	appmw "craftwms/internal/middleware"
	"craftwms/internal/repository"
	"craftwms/internal/service"
)

// StockEntryHandler — HTTP-обработчики сессии ввода остатков (P-FastStart): старт, checkpoint ячейки,
// финал. Доступ — любой аутентифицированный сотрудник (кладовщик проходит склад).
type StockEntryHandler struct {
	svc *service.StockEntryService
}

// NewStockEntryHandler создаёт обработчик сессии ввода остатков.
func NewStockEntryHandler(svc *service.StockEntryService) *StockEntryHandler {
	return &StockEntryHandler{svc: svc}
}

// startRequest — тело POST /stock-entry/sessions.
//
// SessionID необязателен: устройство присылает свой UUID, чтобы адресовать checkpoint'ы офлайн
// (P2-05); пустое поле означает «выдай сам» — так ходит APK, собранная до P2-05.
type startRequest struct {
	SessionID   string `json:"session_id"`
	WarehouseID string `json:"warehouse_id"`
}

// Start: POST /api/v1/stock-entry/sessions — открыть сессию. 201 {session_id} / 400.
// created_by — id аутентифицированного пользователя из токена.
func (h *StockEntryHandler) Start(w http.ResponseWriter, r *http.Request) {
	userID, ok := appmw.UserIDFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	var req startRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "невалидный JSON")
		return
	}
	id, err := h.svc.Start(r.Context(), req.SessionID, req.WarehouseID, userID)
	if err != nil {
		stockEntryError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"session_id": id})
}

// checkpointRequest — тело POST /stock-entry/sessions/{id}/cells.
type checkpointRequest struct {
	CellID      string           `json:"cell_id"`
	Lines       []checkpointLine `json:"lines"`
	NewBarcodes []checkpointBind `json:"new_barcodes"`
}

type checkpointLine struct {
	GoodID         string          `json:"good_id"`
	ProductionDate string          `json:"production_date"` // DD-MM-YYYY
	Qty            decimal.Decimal `json:"qty"`
}

type checkpointBind struct {
	GoodID    string `json:"good_id"`
	Barcode   string `json:"barcode"`
	Symbology string `json:"symbology"`
}

// Checkpoint: POST /api/v1/stock-entry/sessions/{id}/cells — зафиксировать ячейку (строки + новые
// привязки ШК) в сессии. 200 {accepted} / 400 / 404(нет сессии/товара) / 409(закрыта/конфликт ШК).
func (h *StockEntryHandler) Checkpoint(w http.ResponseWriter, r *http.Request) {
	sessionID := chi.URLParam(r, "id")
	var req checkpointRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "невалидный JSON")
		return
	}

	lines := make([]service.EntryLine, len(req.Lines))
	for i, l := range req.Lines {
		lines[i] = service.EntryLine{GoodID: l.GoodID, ProductionDate: l.ProductionDate, Qty: l.Qty}
	}
	barcodes := make([]service.EntryBarcode, len(req.NewBarcodes))
	for i, b := range req.NewBarcodes {
		barcodes[i] = service.EntryBarcode{GoodID: b.GoodID, Barcode: b.Barcode, Symbology: b.Symbology}
	}

	if err := h.svc.Checkpoint(r.Context(), sessionID, req.CellID, lines, barcodes); err != nil {
		stockEntryError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]int{"accepted": len(lines)})
}

// Finalize: POST /api/v1/stock-entry/sessions/{id}/finalize — перенести сессию в остатки и закрыть.
// 200 {written} / 404(нет сессии) / 409(уже закрыта).
func (h *StockEntryHandler) Finalize(w http.ResponseWriter, r *http.Request) {
	sessionID := chi.URLParam(r, "id")
	written, err := h.svc.Finalize(r.Context(), sessionID)
	if err != nil {
		stockEntryError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"written": written, "status": "closed"})
}

// stockEntryError маппит ошибки сервиса/репозитория в HTTP-коды.
func stockEntryError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, service.ErrEmptyWarehouse),
		errors.Is(err, service.ErrEmptyCell),
		errors.Is(err, service.ErrEmptyGoodID),
		errors.Is(err, service.ErrEmptyBarcode),
		errors.Is(err, service.ErrInvalidQuantity),
		errors.Is(err, service.ErrInvalidSessionID),
		errors.Is(err, service.ErrInvalidDate):
		writeError(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, repository.ErrSessionNotFound),
		errors.Is(err, repository.ErrGoodNotFound):
		writeError(w, http.StatusNotFound, err.Error())
	case errors.Is(err, repository.ErrSessionClosed),
		errors.Is(err, repository.ErrBarcodeConflict):
		writeError(w, http.StatusConflict, err.Error())
	default:
		slog.Error("stock entry failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
	}
}
