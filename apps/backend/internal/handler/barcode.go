package handler

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"

	"craftwms/internal/model"
	"craftwms/internal/service"
)

// barcodes - то, что обработчику штрихкодов нужно от сервиса.
type barcodes interface {
	ResolveGood(ctx context.Context, code string) (model.Good, error)
	Bind(ctx context.Context, goodID, barcode, symbology string) error
	Unbind(ctx context.Context, barcode string) error
	List(ctx context.Context, limit, offset int) (service.Page[model.BarcodeLink], error)
	ListByGood(ctx context.Context, goodID string) ([]model.Barcode, error)
	GenerateInternal(ctx context.Context, goodID string) (string, bool, error)
	CZStock(ctx context.Context, barcode string) (int, error)
	Regrade(ctx context.Context, in model.RegradeInput) (model.RegradeResult, error)
}

// BarcodeHandler - HTTP-обработчики привязки ШК к товару и резолва товара по ШК
// (ввод остатков P-FastStart). Доступ - любой аутентифицированный сотрудник (кладовщик на проходе).
type BarcodeHandler struct {
	svc barcodes
}

// NewBarcodeHandler создаёт обработчик штрихкодов.
func NewBarcodeHandler(svc barcodes) *BarcodeHandler {
	return &BarcodeHandler{svc: svc}
}

// GetByCode: GET /api/v1/barcodes/{code} - товар по ШК (200) или 404, если ШК не привязан.
func (h *BarcodeHandler) GetByCode(w http.ResponseWriter, r *http.Request) {
	code := strings.TrimSpace(chi.URLParam(r, "code"))
	good, err := h.svc.ResolveGood(r.Context(), code)
	switch {
	case errors.Is(err, model.ErrEmptyBarcode):
		writeError(w, http.StatusBadRequest, "пустой штрихкод")
		return
	case errors.Is(err, model.ErrNotFound):
		writeError(w, http.StatusNotFound, "штрихкод не привязан")
		return
	case err != nil:
		slog.ErrorContext(r.Context(), "resolve good by barcode failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}
	writeJSON(w, http.StatusOK, good)
}

// ListByGood: GET /api/v1/goods/{id}/barcodes - все ШК товара (секция «Штрихкоды» в карточке).
// 200 со списком (пустой - норма); 400 - пустой id.
func (h *BarcodeHandler) ListByGood(w http.ResponseWriter, r *http.Request) {
	goodID := strings.TrimSpace(chi.URLParam(r, "id"))
	list, err := h.svc.ListByGood(r.Context(), goodID)
	switch {
	case errors.Is(err, model.ErrEmptyGoodID):
		writeError(w, http.StatusBadRequest, "пустой идентификатор товара")
		return
	case err != nil:
		slog.ErrorContext(r.Context(), "list barcodes by good failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}
	writeJSON(w, http.StatusOK, list)
}

// List отдаёт страницу всех привязок ШК - справочник для офлайн-кэша устройства (P2-02).
// Доступ employee, как у остальных справочников: без него не работает скан без сети.
// GenerateInternal: POST /api/v1/goods/{id}/barcode - выдать товару внутренний ШК (P4-07).
// 200 {barcode, generated} / 400 / 404 (нет такого товара).
//
// Идемпотентно: у товара с уже выданным внутренним ШК возвращается он же. Поэтому ответ 200,
// а не 201 - вызов не обещает, что код создан именно сейчас. Признак `generated` говорит,
// что именно произошло: по нему экран решает, печатать ярлык молча или сказать «код уже был».
func (h *BarcodeHandler) GenerateInternal(w http.ResponseWriter, r *http.Request) {
	goodID := strings.TrimSpace(chi.URLParam(r, "id"))
	code, created, err := h.svc.GenerateInternal(r.Context(), goodID)
	switch {
	case errors.Is(err, model.ErrEmptyGoodID):
		writeError(w, http.StatusBadRequest, "пустой идентификатор товара")
		return
	case errors.Is(err, model.ErrGoodNotFound):
		writeError(w, http.StatusNotFound, "товар не найден")
		return
	case err != nil:
		slog.ErrorContext(r.Context(), "generate internal barcode failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"barcode":   code,
		"symbology": "ean13",
		"generated": created,
	})
}

func (h *BarcodeHandler) List(w http.ResponseWriter, r *http.Request) {
	limit, offset := paging(r)
	page, err := h.svc.List(r.Context(), limit, offset)
	if err != nil {
		catalogError(w, r, "list barcodes", err)
		return
	}
	writeJSON(w, http.StatusOK, page)
}

// Unbind: DELETE /api/v1/barcodes/{code} - отвязать ошибочный ШК (P-FS-12).
// 204 - отвязано (идемпотентно: и если ШК уже не было); 400 - пустой код.
func (h *BarcodeHandler) Unbind(w http.ResponseWriter, r *http.Request) {
	code := strings.TrimSpace(chi.URLParam(r, "code"))
	err := h.svc.Unbind(r.Context(), code)
	switch {
	case errors.Is(err, model.ErrEmptyBarcode):
		writeError(w, http.StatusBadRequest, "пустой штрихкод")
		return
	case errors.Is(err, model.ErrBarcodeHasCZStock):
		writeError(w, http.StatusConflict, err.Error())
		return
	case err != nil:
		slog.ErrorContext(r.Context(), "unbind barcode failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// bindRequest - тело POST /api/v1/barcodes.
type bindRequest struct {
	GoodID    string `json:"good_id"`
	Barcode   string `json:"barcode"`
	Symbology string `json:"symbology"` // 'ean13'/'code128'/…; необязательно
}

// Bind: POST /api/v1/barcodes - привязать ШК к товару.
// 201 - привязано (в т.ч. повторно к тому же товару, идемпотентно); 400 - нет good_id/barcode
// или битый JSON; 404 - товара нет; 409 - ШК уже за другим товаром.
func (h *BarcodeHandler) Bind(w http.ResponseWriter, r *http.Request) {
	var req bindRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "невалидный JSON")
		return
	}
	err := h.svc.Bind(r.Context(), req.GoodID, req.Barcode, req.Symbology)
	switch {
	case errors.Is(err, model.ErrEmptyGoodID), errors.Is(err, model.ErrEmptyBarcode):
		writeError(w, http.StatusBadRequest, "нужны good_id и barcode")
		return
	case errors.Is(err, model.ErrGoodNotFound):
		writeError(w, http.StatusNotFound, "товар не найден")
		return
	case errors.Is(err, model.ErrBarcodeConflict):
		writeError(w, http.StatusConflict, "штрихкод уже привязан к другому товару")
		return
	case errors.Is(err, model.ErrBarcodeMarksOtherGood):
		writeError(w, http.StatusConflict, err.Error())
		return
	case err != nil:
		slog.ErrorContext(r.Context(), "bind barcode failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}
	writeJSON(w, http.StatusCreated, req)
}

// CZStock: GET /api/v1/barcodes/{code}/cz-stock - сколько марок ЧЗ с этим ШК на складе
// (ADHOC-53). 200 {marks_in_stock}; ТСД спрашивает перед отвязкой ШК маркируемого товара.
func (h *BarcodeHandler) CZStock(w http.ResponseWriter, r *http.Request) {
	n, err := h.svc.CZStock(r.Context(), chi.URLParam(r, "code"))
	switch {
	case errors.Is(err, model.ErrEmptyBarcode):
		writeError(w, http.StatusBadRequest, "пустой штрихкод")
		return
	case err != nil:
		slog.ErrorContext(r.Context(), "cz stock of barcode failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}
	writeJSON(w, http.StatusOK, map[string]int{"marks_in_stock": n})
}

// regradeRequest - тело POST /api/v1/barcodes/{code}/regrade.
type regradeRequest struct {
	GoodID string `json:"good_id"`
}

// Regrade: POST /api/v1/barcodes/{code}/regrade - перепривязать ШК к другому товару с пересортом
// марок ЧЗ со склада (ADHOC-53). 200 {problem_id, marks}; 400 - нет товара в теле; 409 - отказ
// по существу, текст - для кладовщика.
func (h *BarcodeHandler) Regrade(w http.ResponseWriter, r *http.Request) {
	var req regradeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "невалидный JSON")
		return
	}
	res, err := h.svc.Regrade(r.Context(), model.RegradeInput{
		Barcode: chi.URLParam(r, "code"), GoodID: req.GoodID, UserID: currentUser(r),
	})
	switch {
	case errors.Is(err, model.ErrEmptyBarcode), errors.Is(err, model.ErrEmptyGoodID):
		writeError(w, http.StatusBadRequest, "нужны штрихкод и товар")
		return
	case errors.Is(err, model.ErrGoodNotFound):
		writeError(w, http.StatusNotFound, "товар не найден")
		return
	case model.IsRegradeRefusal(err):
		writeError(w, http.StatusConflict, err.Error())
		return
	case err != nil:
		slog.ErrorContext(r.Context(), "regrade barcode failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"problem_id": res.ProblemID, "marks": res.Marks})
}
