package handler

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"

	"craftwms/internal/repository"
	"craftwms/internal/service"
)

// BarcodeHandler — HTTP-обработчики привязки ШК к товару и резолва товара по ШК
// (ввод остатков P-FastStart). Доступ — любой аутентифицированный сотрудник (кладовщик на проходе).
type BarcodeHandler struct {
	svc *service.BarcodeService
}

// NewBarcodeHandler создаёт обработчик штрихкодов.
func NewBarcodeHandler(svc *service.BarcodeService) *BarcodeHandler {
	return &BarcodeHandler{svc: svc}
}

// GetByCode: GET /api/v1/barcodes/{code} — товар по ШК (200) или 404, если ШК не привязан.
func (h *BarcodeHandler) GetByCode(w http.ResponseWriter, r *http.Request) {
	code := strings.TrimSpace(chi.URLParam(r, "code"))
	good, err := h.svc.ResolveGood(r.Context(), code)
	switch {
	case errors.Is(err, service.ErrEmptyBarcode):
		writeError(w, http.StatusBadRequest, "пустой штрихкод")
		return
	case errors.Is(err, repository.ErrNotFound):
		writeError(w, http.StatusNotFound, "штрихкод не привязан")
		return
	case err != nil:
		slog.Error("resolve good by barcode failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}
	writeJSON(w, http.StatusOK, good)
}

// bindRequest — тело POST /api/v1/barcodes.
type bindRequest struct {
	GoodID    string `json:"good_id"`
	Barcode   string `json:"barcode"`
	Symbology string `json:"symbology"` // 'ean13'/'code128'/…; необязательно
}

// Bind: POST /api/v1/barcodes — привязать ШК к товару.
// 201 — привязано (в т.ч. повторно к тому же товару, идемпотентно); 400 — нет good_id/barcode
// или битый JSON; 404 — товара нет; 409 — ШК уже за другим товаром.
func (h *BarcodeHandler) Bind(w http.ResponseWriter, r *http.Request) {
	var req bindRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "невалидный JSON")
		return
	}
	err := h.svc.Bind(r.Context(), req.GoodID, req.Barcode, req.Symbology)
	switch {
	case errors.Is(err, service.ErrEmptyGoodID), errors.Is(err, service.ErrEmptyBarcode):
		writeError(w, http.StatusBadRequest, "нужны good_id и barcode")
		return
	case errors.Is(err, repository.ErrGoodNotFound):
		writeError(w, http.StatusNotFound, "товар не найден")
		return
	case errors.Is(err, repository.ErrBarcodeConflict):
		writeError(w, http.StatusConflict, "штрихкод уже привязан к другому товару")
		return
	case err != nil:
		slog.Error("bind barcode failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}
	writeJSON(w, http.StatusCreated, req)
}
