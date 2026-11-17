package handler

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/shopspring/decimal"

	appmw "craftwms/internal/middleware"
	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/internal/service"
)

// ReceiptHandler - HTTP-обработчики приёмки (P4-03): документ, строка сканом, оприходование.
// Доступ - любой аутентифицированный сотрудник: приёмку ведёт кладовщик на ТСД.
type ReceiptHandler struct {
	svc *service.ReceiptService
	lu  *service.LoadUnitService
}

// NewReceiptHandler создаёт обработчик приёмки.
func NewReceiptHandler(svc *service.ReceiptService, lu *service.LoadUnitService) *ReceiptHandler {
	return &ReceiptHandler{svc: svc, lu: lu}
}

// createReceiptRequest - тело POST /receipts.
//
// ReceiptID приходит С УСТРОЙСТВА: приёмка начинается на ТСД, в том числе без сети, и серверный
// идентификатор взять неоткуда - кладовщик не смог бы продолжить начатый документ (P4-02).
// SupplierID необязателен: бывает внутреннее поступление и возврат.
type createReceiptRequest struct {
	ReceiptID   string `json:"receipt_id"`
	WarehouseID string `json:"warehouse_id"`
	SupplierID  string `json:"supplier_id"`
	DocNumber   string `json:"doc_number"` // накладная поставщика, обязательна (ADHOC-23)
	DocDate     string `json:"doc_date"`   // DD-MM-YYYY
}

// Create: POST /api/v1/receipts - открыть документ приёмки. 201 {receipt_id} / 400.
// created_by - id аутентифицированного пользователя из токена, а не из тела: иначе устройство
// могло бы записать приёмку на другого человека.
func (h *ReceiptHandler) Create(w http.ResponseWriter, r *http.Request) {
	userID, ok := appmw.UserIDFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	var req createReceiptRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "невалидный JSON")
		return
	}
	if err := h.svc.Start(r.Context(), req.ReceiptID, req.WarehouseID, req.SupplierID, userID, req.DocNumber, req.DocDate); err != nil {
		receiptError(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"receipt_id": req.ReceiptID})
}

// addLineRequest - тело POST /receipts/{id}/lines.
//
// CellID пуст - приходуем в дефолтную ячейку склада (решение заказчика: кладовщик не выбирает
// место на приёмке). LoadUnitID пуст - товар принимают россыпью: грузовая единица добровольна.
type addLineRequest struct {
	GoodID         string          `json:"good_id"`
	ProductionDate string          `json:"production_date"` // DD-MM-YYYY, как на упаковке
	Qty            decimal.Decimal `json:"qty"`
	CellID         string          `json:"cell_id"`
	LoadUnitID     string          `json:"load_unit_id"`
}

// AddLine: POST /api/v1/receipts/{id}/lines - добавить строку сканом.
// 200 {accepted} / 400 / 404(нет документа/товара/ГЕ) / 409(документ проведён).
//
// Повторный скан той же комбинации (товар · партия · ячейка · ГЕ) увеличивает количество,
// а не плодит строки - поэтому ответ один и тот же и на первый скан, и на повторный.
func (h *ReceiptHandler) AddLine(w http.ResponseWriter, r *http.Request) {
	receiptID := chi.URLParam(r, "id")
	var req addLineRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "невалидный JSON")
		return
	}
	cellID, err := h.svc.AddLine(r.Context(), receiptID, req.GoodID, req.ProductionDate,
		req.CellID, req.LoadUnitID, req.Qty)
	if err != nil {
		receiptError(w, r, err)
		return
	}
	// Отдаём ячейку: если кладовщик её не указывал, это та самая дефолтная, и он должен
	// увидеть, куда принят товар.
	writeJSON(w, http.StatusOK, map[string]string{"cell_id": cellID})
}

// Post: POST /api/v1/receipts/{id}/post - оприходовать документ.
// 200 {posted, status} / 404(нет документа) / 409(уже проведён, пуст, короб в двух ячейках).
//
// Повтор здесь опасен - оприходование ДОБАВЛЯЕТ к остатку, - и закрыт статусом: второй вызов
// получает 409, а не удваивает приход (P4-02).
func (h *ReceiptHandler) Post(w http.ResponseWriter, r *http.Request) {
	receiptID := chi.URLParam(r, "id")
	posted, err := h.svc.Post(r.Context(), receiptID)
	if err != nil {
		receiptError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"posted": posted, "status": model.ReceiptPosted})
}

// receiptResponse - документ приёмки для показа кладовщику.
type receiptResponse struct {
	ReceiptID   string              `json:"receipt_id"`
	WarehouseID string              `json:"warehouse_id"`
	SupplierID  *string             `json:"supplier_id"`
	Status      string              `json:"status"`
	PostedAt    *time.Time          `json:"posted_at"`
	Lines       []receiptLineOutput `json:"lines"`
}

// receiptLineOutput - строка документа с наименованием товара и адресом ячейки: на экране ТСД
// кладовщик видит их, а не идентификаторы.
type receiptLineOutput struct {
	GoodID      string          `json:"good_id"`
	GoodName    string          `json:"good_name"`
	BatchID     string          `json:"batch_id"`
	CellID      string          `json:"cell_id"`
	CellAddress string          `json:"cell_address"`
	LoadUnitID  *string         `json:"load_unit_id"`
	Qty         decimal.Decimal `json:"qty"`
}

// Get: GET /api/v1/receipts/{id} - шапка документа и его строки. 200 / 404.
func (h *ReceiptHandler) Get(w http.ResponseWriter, r *http.Request) {
	receiptID := chi.URLParam(r, "id")
	rc, lines, err := h.svc.Get(r.Context(), receiptID)
	if err != nil {
		receiptError(w, r, err)
		return
	}
	out := receiptResponse{
		ReceiptID: rc.ID, WarehouseID: rc.WarehouseID, SupplierID: rc.SupplierID,
		Status: rc.Status, PostedAt: rc.PostedAt,
		Lines: make([]receiptLineOutput, 0, len(lines)),
	}
	for _, ln := range lines {
		out.Lines = append(out.Lines, receiptLineOutput{
			GoodID: ln.GoodID, GoodName: ln.GoodName, BatchID: ln.BatchID,
			CellID: ln.CellID, CellAddress: ln.CellAddress,
			LoadUnitID: ln.LoadUnitID, Qty: ln.Qty,
		})
	}
	writeJSON(w, http.StatusOK, out)
}

// createLoadUnitRequest - тело POST /load-units. Kind пуст → короб: приёмка собирает короба,
// паллета - явный выбор.
type createLoadUnitRequest struct {
	LoadUnitID string `json:"load_unit_id"`
	Kind       string `json:"kind"`
}

// CreateLoadUnit: POST /api/v1/load-units - завести ГЕ с идентификатором из QR ярлыка.
// 201 {load_unit_id} / 400.
//
// Отдельной ручкой, а не полем строки приёмки: короб собирают и печатают ему ярлык ДО того,
// как в него положили первую позицию, и ГЕ живёт дальше приёмки - её двигают в P5 и P6.
func (h *ReceiptHandler) CreateLoadUnit(w http.ResponseWriter, r *http.Request) {
	var req createLoadUnitRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "невалидный JSON")
		return
	}
	if err := h.lu.Create(r.Context(), req.LoadUnitID, req.Kind); err != nil {
		receiptError(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"load_unit_id": req.LoadUnitID})
}

// loadUnitResponse - шапка ГЕ для показа кладовщику.
type loadUnitResponse struct {
	LoadUnitID string  `json:"load_unit_id"`
	Kind       string  `json:"kind"`
	Status     string  `json:"status"`
	CellID     *string `json:"cell_id"`
	ParentID   *string `json:"parent_id"`
}

// GetLoadUnit: GET /api/v1/load-units/{id} - что за короб отсканировали. 200 / 400 / 404.
func (h *ReceiptHandler) GetLoadUnit(w http.ResponseWriter, r *http.Request) {
	lu, err := h.lu.Get(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		receiptError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, loadUnitResponse{
		LoadUnitID: lu.ID, Kind: lu.Kind, Status: lu.Status,
		CellID: lu.CellID, ParentID: lu.ParentID,
	})
}

// receiptError маппит ошибки сервиса/репозитория в HTTP-коды.
//
// Граница 404/409 проведена по смыслу для кладовщика: 404 - «того, что ты отсканировал, нет»
// (документ, товар, короб), 409 - «оно есть, но в таком состоянии этого делать нельзя»
// (документ проведён, пуст, короб числится в двух ячейках). Отсутствие дефолтной ячейки -
// 500: это незавершённое развёртывание, а не ошибка человека, и чинится не на терминале.
func receiptError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, service.ErrEmptyReceiptID),
		errors.Is(err, service.ErrEmptyWarehouse),
		errors.Is(err, service.ErrEmptyGoodID),
		errors.Is(err, service.ErrInvalidQuantity),
		errors.Is(err, service.ErrInvalidDate),
		errors.Is(err, service.ErrInvalidLoadUnitID),
		errors.Is(err, service.ErrInvalidLoadUnitKind),
		errors.Is(err, service.ErrEmptyDocNumber),
		errors.Is(err, service.ErrDocNumberTooLong),
		errors.Is(err, service.ErrInvalidDocDate):
		writeError(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, repository.ErrReceiptNotFound),
		errors.Is(err, repository.ErrGoodNotFound),
		errors.Is(err, repository.ErrLoadUnitNotFound):
		writeError(w, http.StatusNotFound, err.Error())
	case errors.Is(err, repository.ErrReceiptPosted),
		errors.Is(err, repository.ErrEmptyReceipt),
		errors.Is(err, repository.ErrLoadUnitCellConflict):
		writeError(w, http.StatusConflict, err.Error())
	case errors.Is(err, service.ErrNoDefaultCell):
		slog.ErrorContext(r.Context(), "receiving without default cell", "error", err)
		writeError(w, http.StatusInternalServerError, err.Error())
	default:
		slog.ErrorContext(r.Context(), "receipt failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
	}
}
