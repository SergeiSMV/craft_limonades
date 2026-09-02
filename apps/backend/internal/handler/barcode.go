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

// ListByGood: GET /api/v1/goods/{id}/barcodes — все ШК товара (секция «Штрихкоды» в карточке).
// 200 со списком (пустой — норма); 400 — пустой id.
func (h *BarcodeHandler) ListByGood(w http.ResponseWriter, r *http.Request) {
	goodID := strings.TrimSpace(chi.URLParam(r, "id"))
	list, err := h.svc.ListByGood(r.Context(), goodID)
	switch {
	case errors.Is(err, service.ErrEmptyGoodID):
		writeError(w, http.StatusBadRequest, "пустой идентификатор товара")
		return
	case err != nil:
		slog.Error("list barcodes by good failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}
	writeJSON(w, http.StatusOK, list)
}

// List отдаёт страницу всех привязок ШК — справочник для офлайн-кэша устройства (P2-02).
// Доступ employee, как у остальных справочников: без него не работает скан без сети.
func (h *BarcodeHandler) List(w http.ResponseWriter, r *http.Request) {
	limit, offset := paging(r)
	page, err := h.svc.List(r.Context(), limit, offset)
	if err != nil {
		catalogError(w, "list barcodes", err)
		return
	}
	writeJSON(w, http.StatusOK, page)
}

// Unbind: DELETE /api/v1/barcodes/{code} — отвязать ошибочный ШК (P-FS-12).
// 204 — отвязано (идемпотентно: и если ШК уже не было); 400 — пустой код.
func (h *BarcodeHandler) Unbind(w http.ResponseWriter, r *http.Request) {
	code := strings.TrimSpace(chi.URLParam(r, "code"))
	err := h.svc.Unbind(r.Context(), code)
	switch {
	case errors.Is(err, service.ErrEmptyBarcode):
		writeError(w, http.StatusBadRequest, "пустой штрихкод")
		return
	case err != nil:
		slog.Error("unbind barcode failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}
	w.WriteHeader(http.StatusNoContent)
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
