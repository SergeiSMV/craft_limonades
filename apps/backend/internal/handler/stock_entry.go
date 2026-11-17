package handler

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/shopspring/decimal"

	appmw "craftwms/internal/middleware"
	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/internal/service"
)

// StockEntryHandler - HTTP-обработчики сессии ввода остатков (P-FastStart): старт, checkpoint ячейки,
// финал. Доступ - любой аутентифицированный сотрудник (кладовщик проходит склад).
type StockEntryHandler struct {
	svc *service.StockEntryService
}

// NewStockEntryHandler создаёт обработчик сессии ввода остатков.
func NewStockEntryHandler(svc *service.StockEntryService) *StockEntryHandler {
	return &StockEntryHandler{svc: svc}
}

// startRequest - тело POST /stock-entry/sessions.
//
// SessionID необязателен: устройство присылает свой UUID, чтобы адресовать checkpoint'ы офлайн
// (P2-05); пустое поле означает «выдай сам» - так ходит APK, собранная до P2-05.
type startRequest struct {
	SessionID   string `json:"session_id"`
	WarehouseID string `json:"warehouse_id"`
}

// Start: POST /api/v1/stock-entry/sessions - открыть сессию. 201 {session_id} / 400.
// created_by - id аутентифицированного пользователя из токена.
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
		stockEntryError(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"session_id": id})
}

// checkpointRequest - тело POST /stock-entry/sessions/{id}/cells.
//
// Короба, упаковки ЧЗ и марки строк (ADHOC-46) необязательны: APK до ADHOC-46 их не шлёт, и
// её проход идёт по-прежнему, россыпью.
type checkpointRequest struct {
	CellID      string               `json:"cell_id"`
	Lines       []checkpointLine     `json:"lines"`
	LoadUnits   []checkpointLoadUnit `json:"load_units"`
	CZGroups    []checkpointCZGroup  `json:"cz_groups"`
	NewBarcodes []checkpointBind     `json:"new_barcodes"`
}

type checkpointLine struct {
	GoodID         string           `json:"good_id"`
	ProductionDate string           `json:"production_date"` // DD-MM-YYYY
	Qty            decimal.Decimal  `json:"qty"`
	LoadUnitID     string           `json:"load_unit_id"` // короб ячейки; пусто - россыпь
	Marks          []checkpointMark `json:"marks"`
}

// checkpointLoadUnit - короб ячейки прохода: свой с QR (id из ярлыка) или короб ЧЗ.
type checkpointLoadUnit struct {
	ID     string `json:"id"`
	Kind   string `json:"kind"`
	CZCode string `json:"cz_code"` // `00`+SSCC; пусто - свой короб
}

type checkpointCZGroup struct {
	Code       string `json:"code"`
	ParentCode string `json:"parent_code"`
}

type checkpointMark struct {
	CIS           string `json:"cis"`
	AggregateCode string `json:"aggregate_code"`
	Discrepancy   string `json:"discrepancy"`
}

type checkpointBind struct {
	GoodID    string `json:"good_id"`
	Barcode   string `json:"barcode"`
	Symbology string `json:"symbology"`
}

// Checkpoint: POST /api/v1/stock-entry/sessions/{id}/cells - зафиксировать ячейку (строки, короба,
// марки, новые привязки ШК) в сессии. 200 {accepted} / 400 / 404(нет сессии/товара) /
// 409(закрыта/конфликт ШК) / 422(отказ строк - текст со списком плохих строк).
func (h *StockEntryHandler) Checkpoint(w http.ResponseWriter, r *http.Request) {
	sessionID := chi.URLParam(r, "id")
	var req checkpointRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "невалидный JSON")
		return
	}

	cell := service.EntryCell{CellID: req.CellID}
	for _, l := range req.Lines {
		line := service.EntryLine{
			GoodID: l.GoodID, ProductionDate: l.ProductionDate, Qty: l.Qty, LoadUnitID: l.LoadUnitID,
		}
		for _, m := range l.Marks {
			line.Marks = append(line.Marks, service.EntryMark{
				CIS: m.CIS, AggregateCode: m.AggregateCode, Discrepancy: m.Discrepancy,
			})
		}
		cell.Lines = append(cell.Lines, line)
	}
	for _, lu := range req.LoadUnits {
		cell.LoadUnits = append(cell.LoadUnits, service.EntryLoadUnit{ID: lu.ID, Kind: lu.Kind, CZCode: lu.CZCode})
	}
	for _, g := range req.CZGroups {
		cell.CZGroups = append(cell.CZGroups, service.EntryGroup{Code: g.Code, ParentCode: g.ParentCode})
	}
	for _, b := range req.NewBarcodes {
		cell.Barcodes = append(cell.Barcodes, service.EntryBarcode{GoodID: b.GoodID, Barcode: b.Barcode, Symbology: b.Symbology})
	}

	if err := h.svc.Checkpoint(r.Context(), sessionID, cell); err != nil {
		stockEntryError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]int{"accepted": len(cell.Lines)})
}

// Finalize: POST /api/v1/stock-entry/sessions/{id}/finalize - перенести сессию в остатки и закрыть.
// 200 {written} / 404(нет сессии) / 409(уже закрыта) / 422(отказ строк).
func (h *StockEntryHandler) Finalize(w http.ResponseWriter, r *http.Request) {
	sessionID := chi.URLParam(r, "id")
	written, err := h.svc.Finalize(r.Context(), sessionID)
	if err != nil {
		stockEntryError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"written": written, "status": "closed"})
}

// stockEntryError маппит ошибки сервиса/репозитория в HTTP-коды.
//
// Отказ строк (ADHOC-46) - первым: его Unwrap отдаёт причины строк, и errors.Is ниже принял бы
// его за ошибку формы. Текст - по-русски со списком строк, ТСД показывает его как есть.
func stockEntryError(w http.ResponseWriter, r *http.Request, err error) {
	var lines *repository.DocumentLinesError
	if errors.As(err, &lines) {
		writeError(w, http.StatusUnprocessableEntity, lines.Error())
		return
	}
	switch {
	case errors.Is(err, model.ErrEmptyWarehouse),
		errors.Is(err, model.ErrEmptyCell),
		errors.Is(err, model.ErrEmptyGoodID),
		errors.Is(err, model.ErrEmptyBarcode),
		errors.Is(err, model.ErrInvalidQuantity),
		errors.Is(err, model.ErrInvalidSessionID),
		errors.Is(err, model.ErrInvalidDate),
		errors.Is(err, model.ErrInvalidPayload),
		errors.Is(err, model.ErrInvalidLoadUnitID),
		errors.Is(err, model.ErrInvalidLoadUnitKind),
		errors.Is(err, model.ErrCZBadCode),
		errors.Is(err, model.ErrCZMarksExceedQty),
		errors.Is(err, model.ErrCZMarkExists),
		errors.Is(err, model.ErrCZAggregateExists):
		writeError(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, model.ErrSessionNotFound),
		errors.Is(err, model.ErrGoodNotFound):
		writeError(w, http.StatusNotFound, err.Error())
	case errors.Is(err, model.ErrSessionClosed),
		errors.Is(err, model.ErrBarcodeConflict):
		writeError(w, http.StatusConflict, err.Error())
	// GTIN марки на финале не нашёлся у товара строки (ADHOC-46): привязка ШК из марки ещё
	// не дошла из очереди или ушла к другому товару. Повтор после отправки очереди поможет -
	// это не сбой сервера.
	case errors.Is(err, model.ErrCZUnknownGTIN), errors.Is(err, model.ErrCZMarkGoodMismatch):
		writeError(w, http.StatusConflict,
			"ШК марки не привязан к товару строки - отправьте очередь и повторите: "+err.Error())
	default:
		slog.ErrorContext(r.Context(), "stock entry failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
	}
}
