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
	"craftwms/internal/picking"
	"craftwms/internal/service"
)

// PickingTSDHandler — сборка на ТСД (P9-04): список «СБОРКА», заказ с подбором, взять,
// отказаться, короб отгрузки, «не хватает». Всё — онлайн: взятие закрепляет заказ за одним
// кладовщиком, а это решает сервер.
type PickingTSDHandler struct {
	svc *service.PickingTaskService
}

// NewPickingTSDHandler создаёт обработчик сборки на ТСД.
func NewPickingTSDHandler(svc *service.PickingTaskService) *PickingTSDHandler {
	return &PickingTSDHandler{svc: svc}
}

type pickingListItemDTO struct {
	ID            string `json:"id"`
	Number        int64  `json:"number"`
	RegistryDate  string `json:"registry_date"`
	InvoiceNumber string `json:"invoice_number"`
	OrderNumber   string `json:"order_number"`
	Direction     string `json:"direction"`
	Client        string `json:"client"`
	Address       string `json:"address"`
	Status        string `json:"status"`
	HasUnknown    bool   `json:"has_unknown"`
	Lines         int    `json:"lines"`
	Mine          bool   `json:"mine"`
	Busy          bool   `json:"busy"`
	AssigneeName  string `json:"assignee_name,omitempty"`
	IsPartial     bool   `json:"is_partial"`
	Boxes         int    `json:"boxes"`
}

type pickingTakeDTO struct {
	CellID              string          `json:"cell_id"`
	CellAddress         string          `json:"cell_address"`
	IsFloorStorage      bool            `json:"is_floor_storage"`
	LoadUnitID          string          `json:"load_unit_id,omitempty"`
	InternalWarehouseID string          `json:"internal_warehouse_id"`
	BatchID             string          `json:"batch_id"`
	BatchDate           string          `json:"batch_date"`
	Qty                 decimal.Decimal `json:"qty"`
}

type pickingSuggestionDTO struct {
	Remaining        decimal.Decimal  `json:"remaining"`
	Short            decimal.Decimal  `json:"short"`
	BatchSubstituted bool             `json:"batch_substituted"`
	CellSubstituted  bool             `json:"cell_substituted"`
	Takes            []pickingTakeDTO `json:"takes"`
}

type pickingLineDTO struct {
	ID           string                `json:"id"`
	LineNo       int                   `json:"line_no"`
	GoodID       *string               `json:"good_id"`
	GoodCode     string                `json:"good_code"`
	GoodName     string                `json:"good_name"`
	Uom          string                `json:"uom"`
	CZMarked     bool                  `json:"cz_marked"`
	BatchDate    *string               `json:"batch_date"`
	RegistryCell string                `json:"registry_cell"`
	CellID       *string               `json:"cell_id"`
	CellAddress  string                `json:"cell_address"`
	PlanQty      int                   `json:"plan_qty"`
	Taken        decimal.Decimal       `json:"taken"`
	Removed      bool                  `json:"removed"`
	Shortage     bool                  `json:"shortage"`
	Suggestion   *pickingSuggestionDTO `json:"suggestion"`
}

type pickingBoxDTO struct {
	LoadUnitID string `json:"load_unit_id"`
	Seq        int    `json:"seq"`
}

type pickingPickDTO struct {
	ID             string          `json:"id"`
	LineID         string          `json:"line_id"`
	BoxID          string          `json:"box_id"`
	CellAddress    string          `json:"cell_address"`
	LoadUnitID     string          `json:"load_unit_id,omitempty"`
	ProductionDate string          `json:"production_date"`
	Qty            decimal.Decimal `json:"qty"`
	Marks          []string        `json:"marks"`
}

type pickingOrderDTO struct {
	ID            string           `json:"id"`
	Number        int64            `json:"number"`
	RegistryDate  string           `json:"registry_date"`
	InvoiceNumber string           `json:"invoice_number"`
	OrderNumber   string           `json:"order_number"`
	Direction     string           `json:"direction"`
	Client        string           `json:"client"`
	Address       string           `json:"address"`
	Status        string           `json:"status"`
	Mine          bool             `json:"mine"`
	Lines         []pickingLineDTO `json:"lines"`
	Boxes         []pickingBoxDTO  `json:"boxes"`
	Picks         []pickingPickDTO `json:"picks"`
}

// Orders: GET /api/v1/picking/orders — список «СБОРКА»: несобранные заказы любой даты. 200.
func (h *PickingTSDHandler) Orders(w http.ResponseWriter, r *http.Request) {
	userID, _ := appmw.UserIDFromContext(r.Context())
	items, err := h.svc.Orders(r.Context(), userID)
	if err != nil {
		h.fail(w, r, err, "orders")
		return
	}
	out := make([]pickingListItemDTO, 0, len(items))
	for _, it := range items {
		out = append(out, pickingListItemDTO{
			ID: it.ID, Number: it.Number, RegistryDate: it.RegistryDate.Format(time.DateOnly),
			InvoiceNumber: it.InvoiceNumber, OrderNumber: it.OrderNumber, Direction: it.Direction,
			Client: it.Client, Address: it.Address, Status: it.Status, HasUnknown: it.HasUnknown,
			Lines: it.Lines, Mine: it.Mine, Busy: it.Busy, AssigneeName: it.AssigneeName,
			IsPartial: it.IsPartial, Boxes: it.Boxes,
		})
	}
	writeJSON(w, http.StatusOK, out)
}

// Order: GET /api/v1/picking/orders/{id} — заказ с подбором по строкам и коробами отгрузки.
// 200 / 404 / 409 (удалён в 1С, нераспознанные позиции, собран).
func (h *PickingTSDHandler) Order(w http.ResponseWriter, r *http.Request) {
	userID, _ := appmw.UserIDFromContext(r.Context())
	task, err := h.svc.Task(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		h.fail(w, r, err, "order")
		return
	}
	writeJSON(w, http.StatusOK, pickingOrderOut(task, userID))
}

// Take: POST /api/v1/picking/orders/{id}/take — взять в работу. 204 / 404 / 409.
func (h *PickingTSDHandler) Take(w http.ResponseWriter, r *http.Request) {
	userID, _ := appmw.UserIDFromContext(r.Context())
	if err := h.svc.Take(r.Context(), chi.URLParam(r, "id"), userID); err != nil {
		h.fail(w, r, err, "take")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// Release: POST /api/v1/picking/orders/{id}/release — отказаться: заказ снова «новый». 204 / 404 / 409.
func (h *PickingTSDHandler) Release(w http.ResponseWriter, r *http.Request) {
	userID, _ := appmw.UserIDFromContext(r.Context())
	if err := h.svc.Release(r.Context(), chi.URLParam(r, "id"), userID); err != nil {
		h.fail(w, r, err, "release")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// AddBox: POST /api/v1/picking/orders/{id}/boxes {"load_unit_id": "<uuid ярлыка>"} — завести
// короб отгрузки. 200 {"load_unit_id", "seq"} / 400 / 404 / 409.
func (h *PickingTSDHandler) AddBox(w http.ResponseWriter, r *http.Request) {
	var req struct {
		LoadUnitID string `json:"load_unit_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "ожидается JSON с полем load_unit_id")
		return
	}
	userID, _ := appmw.UserIDFromContext(r.Context())
	seq, err := h.svc.AddBox(r.Context(), chi.URLParam(r, "id"), userID, req.LoadUnitID)
	if err != nil {
		h.fail(w, r, err, "box")
		return
	}
	writeJSON(w, http.StatusOK, pickingBoxDTO{LoadUnitID: req.LoadUnitID, Seq: seq})
}

// Shortage: POST /api/v1/picking/orders/{id}/lines/{lineId}/shortage {"shortage": true|false} —
// отметка «не хватает». 200 {"stocktake_number", "stocktake_created"} / 400 / 404 / 409.
func (h *PickingTSDHandler) Shortage(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Shortage *bool `json:"shortage"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Shortage == nil {
		writeError(w, http.StatusBadRequest, "ожидается JSON с полем shortage")
		return
	}
	userID, _ := appmw.UserIDFromContext(r.Context())
	res, err := h.svc.MarkShortage(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "lineId"), userID, *req.Shortage)
	if err != nil {
		h.fail(w, r, err, "shortage")
		return
	}
	writeJSON(w, http.StatusOK, struct {
		StocktakeNumber  *int64 `json:"stocktake_number"`
		StocktakeCreated bool   `json:"stocktake_created"`
	}{res.StocktakeNumber, res.Created})
}

type pickingShipmentBoxDTO struct {
	LoadUnitID    string          `json:"load_unit_id"`
	Seq           int             `json:"seq"`
	Qty           decimal.Decimal `json:"qty"`
	LabelsPrinted int             `json:"labels_printed"`
	Shipped       bool            `json:"shipped"`
}

type pickingShipmentDTO struct {
	ID            string                  `json:"id"`
	Number        int64                   `json:"number"`
	RegistryDate  string                  `json:"registry_date"`
	InvoiceNumber string                  `json:"invoice_number"`
	OrderNumber   string                  `json:"order_number"`
	Direction     string                  `json:"direction"`
	Client        string                  `json:"client"`
	Address       string                  `json:"address"`
	Status        string                  `json:"status"`
	IsPartial     bool                    `json:"is_partial"`
	Deleted       bool                    `json:"deleted"`
	Qty           decimal.Decimal         `json:"qty"`
	Boxes         []pickingShipmentBoxDTO `json:"boxes"`
}

// Shipment: GET /api/v1/picking/orders/{id}/shipment — собранный заказ с коробами «N из M» для
// ярлыков и отгрузки (P9-07). 200 / 404.
func (h *PickingTSDHandler) Shipment(w http.ResponseWriter, r *http.Request) {
	s, err := h.svc.Shipment(r.Context(), chi.URLParam(r, "id"))
	h.shipmentOut(w, r, s, err, "shipment")
}

// Complete: POST /api/v1/picking/orders/{id}/complete — «Завершить сборку»: остаток в короба
// отгрузки, короба в `ОТГРУЗКУ`, заказ «собран». 200 (заказ с коробами) / 404 / 409 (не у вас,
// строки не собраны или взято лишнее — текст со списком товаров).
func (h *PickingTSDHandler) Complete(w http.ResponseWriter, r *http.Request) {
	userID, _ := appmw.UserIDFromContext(r.Context())
	s, err := h.svc.Complete(r.Context(), chi.URLParam(r, "id"), userID)
	h.shipmentOut(w, r, s, err, "complete")
}

// boxIDsRequest — тело ярлыков и отгрузки: короба заказа.
type boxIDsRequest struct {
	BoxIDs []string `json:"box_ids"`
}

// Labels: POST /api/v1/picking/orders/{id}/labels {"box_ids": [...]} — отметить печать ярлыков и
// получить данные для них. Уже печатавшийся ярлык — только с правом tsd.picking.reprint.
// 200 / 400 / 403 (повтор без права) / 404 / 409.
func (h *PickingTSDHandler) Labels(w http.ResponseWriter, r *http.Request) {
	var req boxIDsRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "ожидается JSON с полем box_ids")
		return
	}
	access, _ := appmw.AccessFromContext(r.Context())
	s, err := h.svc.PrintLabels(r.Context(), chi.URLParam(r, "id"), req.BoxIDs, access.Can(model.RightTSDPickingReprint))
	h.shipmentOut(w, r, s, err, "labels")
}

// Ship: POST /api/v1/picking/orders/{id}/ship {"box_ids": [...]} — «Отгрузить»: отсканированы
// ярлыки всех коробов, товар уходит со склада. 200 / 400 / 404 / 409.
func (h *PickingTSDHandler) Ship(w http.ResponseWriter, r *http.Request) {
	var req boxIDsRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "ожидается JSON с полем box_ids")
		return
	}
	userID, _ := appmw.UserIDFromContext(r.Context())
	s, err := h.svc.Ship(r.Context(), chi.URLParam(r, "id"), userID, req.BoxIDs)
	h.shipmentOut(w, r, s, err, "ship")
}

// shipmentOut — заказ с коробами в ответ или отказ.
func (h *PickingTSDHandler) shipmentOut(w http.ResponseWriter, r *http.Request, s model.PickingShipment, err error, action string) {
	if err != nil {
		h.fail(w, r, err, action)
		return
	}
	out := pickingShipmentDTO{
		ID: s.ID, Number: s.Number, RegistryDate: s.RegistryDate.Format(time.DateOnly),
		InvoiceNumber: s.InvoiceNumber, OrderNumber: s.OrderNumber, Direction: s.Direction,
		Client: s.Client, Address: s.Address, Status: s.Status, IsPartial: s.IsPartial,
		Deleted: s.Deleted, Qty: s.Qty, Boxes: make([]pickingShipmentBoxDTO, 0, len(s.Boxes)),
	}
	for _, b := range s.Boxes {
		out.Boxes = append(out.Boxes, pickingShipmentBoxDTO{
			LoadUnitID: b.LoadUnitID, Seq: b.Seq, Qty: b.Qty, LabelsPrinted: b.LabelsPrinted, Shipped: b.Shipped,
		})
	}
	writeJSON(w, http.StatusOK, out)
}

// fail — отказ по состоянию заказа текстом для кладовщика, остальное — 500.
func (h *PickingTSDHandler) fail(w http.ResponseWriter, r *http.Request, err error, action string) {
	var lines *model.PickingLinesError
	switch {
	case errors.As(err, &lines):
		writeError(w, http.StatusConflict, err.Error())
	case errors.Is(err, model.ErrPickingReprintDenied):
		writeError(w, http.StatusForbidden, err.Error())
	case errors.Is(err, model.ErrPickingNothingTaken), errors.Is(err, model.ErrPickingNotPicked),
		errors.Is(err, model.ErrPickingShipBoxes), errors.Is(err, model.ErrPickingStockShort):
		writeError(w, http.StatusConflict, err.Error())
	case errors.Is(err, model.ErrPickingOrderNotFound), errors.Is(err, model.ErrPickingLineNotFound):
		writeError(w, http.StatusNotFound, err.Error())
	case errors.Is(err, model.ErrPickingBoxID):
		writeError(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, model.ErrPickingOrderDeleted), errors.Is(err, model.ErrPickingOrderUnknown),
		errors.Is(err, model.ErrPickingOrderClosed), errors.Is(err, model.ErrPickingOrderTaken),
		errors.Is(err, model.ErrPickingOrderNotYours), errors.Is(err, model.ErrPickingBoxForeign):
		writeError(w, http.StatusConflict, err.Error())
	default:
		slog.ErrorContext(r.Context(), "picking tsd failed", "action", action, "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
	}
}

// pickingOrderOut — заказ с подбором в ответ ТСД.
func pickingOrderOut(task service.PickingTask, userID string) pickingOrderDTO {
	o := task.Order
	out := pickingOrderDTO{
		ID: o.ID, Number: o.Number, RegistryDate: o.RegistryDate.Format(time.DateOnly),
		InvoiceNumber: o.InvoiceNumber, OrderNumber: o.OrderNumber, Direction: o.Direction,
		Client: o.Client, Address: o.Address, Status: o.Status,
		Mine:  o.AssigneeID != nil && *o.AssigneeID == userID,
		Lines: make([]pickingLineDTO, 0, len(task.Lines)), Boxes: make([]pickingBoxDTO, 0, len(o.Boxes)),
		Picks: make([]pickingPickDTO, 0, len(o.Picks)),
	}
	for _, tl := range task.Lines {
		l := tl.Line
		dto := pickingLineDTO{
			ID: l.ID, LineNo: l.LineNo, GoodID: l.GoodID, GoodCode: l.GoodCode, GoodName: l.GoodName,
			Uom: l.Uom, CZMarked: l.CZMarked, RegistryCell: l.RegistryCell, CellID: l.CellID,
			CellAddress: l.CellAddress, PlanQty: l.PlanQty, Taken: l.Taken, Removed: l.Removed,
			Shortage: l.Shortage, Suggestion: suggestionOut(tl.Suggestion),
		}
		if l.BatchDate != nil {
			d := l.BatchDate.Format(time.DateOnly)
			dto.BatchDate = &d
		}
		out.Lines = append(out.Lines, dto)
	}
	for _, b := range o.Boxes {
		out.Boxes = append(out.Boxes, pickingBoxDTO{LoadUnitID: b.LoadUnitID, Seq: b.Seq})
	}
	// Дата партии - DD-MM-YYYY, как в теле пика и в снимке содержимого склада.
	for _, p := range o.Picks {
		marks := p.Marks
		if marks == nil {
			marks = []string{}
		}
		out.Picks = append(out.Picks, pickingPickDTO{
			ID: p.ID, LineID: p.LineID, BoxID: p.BoxID, CellAddress: p.CellAddress,
			LoadUnitID: p.LoadUnitID, ProductionDate: p.BatchDate.Format("02-01-2006"),
			Qty: p.Qty, Marks: marks,
		})
	}
	return out
}

func suggestionOut(sg *picking.Suggestion) *pickingSuggestionDTO {
	if sg == nil {
		return nil
	}
	out := &pickingSuggestionDTO{
		Remaining: sg.Remaining, Short: sg.Short,
		BatchSubstituted: sg.BatchSubstituted, CellSubstituted: sg.CellSubstituted,
		Takes: make([]pickingTakeDTO, 0, len(sg.Takes)),
	}
	for _, t := range sg.Takes {
		s := t.Source
		out.Takes = append(out.Takes, pickingTakeDTO{
			CellID: s.CellID, CellAddress: s.CellAddress, IsFloorStorage: s.IsFloorStorage,
			LoadUnitID: s.LoadUnitID, InternalWarehouseID: s.InternalWarehouseID,
			BatchID: s.BatchID, BatchDate: s.BatchDate.Format(time.DateOnly), Qty: t.Qty,
		})
	}
	return out
}
