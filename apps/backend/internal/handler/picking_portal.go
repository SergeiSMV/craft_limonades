package handler

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/shopspring/decimal"

	appmw "craftwms/internal/middleware"
	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// pickingPortal — узкий интерфейс сервиса раздела «Сборка-отгрузка» (P8-03).
type pickingPortal interface {
	Orders(ctx context.Context, warehouseCode string, date time.Time) ([]model.PickingPortalOrder, error)
	Order(ctx context.Context, orderID string) (model.PickingPortalDetail, error)
	Release(ctx context.Context, orderID, leadID string) error
	ExportXLSX(ctx context.Context, warehouseCode string, date time.Time) ([]byte, string, error)
}

// PickingPortalHandler — «Сборка-отгрузка» в портале (P8-03): заказы на дату накладной, окно
// деталей, выгрузка Excel, снятие заказа с исполнителя.
type PickingPortalHandler struct {
	svc pickingPortal
}

// NewPickingPortalHandler создаёт обработчик раздела.
func NewPickingPortalHandler(svc pickingPortal) *PickingPortalHandler {
	return &PickingPortalHandler{svc: svc}
}

type pickingPortalOrderDTO struct {
	ID                   string          `json:"id"`
	Number               int64           `json:"number"`
	RegistryDate         string          `json:"registry_date"`
	InvoiceNumber        string          `json:"invoice_number"`
	OrderNumber          string          `json:"order_number"`
	OrderDate            *string         `json:"order_date"`
	Direction            string          `json:"direction"`
	Client               string          `json:"client"`
	Address              string          `json:"address"`
	Status               string          `json:"status"`
	IsPartial            bool            `json:"is_partial"`
	HasUnknown           bool            `json:"has_unknown"`
	Deleted              bool            `json:"deleted"`
	ChangedAfterShipment bool            `json:"changed_after_shipment"`
	AssigneeName         string          `json:"assignee_name"`
	TakenAt              *time.Time      `json:"taken_at"`
	PickedByName         string          `json:"picked_by_name"`
	PickedAt             *time.Time      `json:"picked_at"`
	ShippedAt            *time.Time      `json:"shipped_at"`
	Lines                int             `json:"lines"`
	PlanQty              int             `json:"plan_qty"`
	FactQty              decimal.Decimal `json:"fact_qty"`
	Boxes                int             `json:"boxes"`
	ReturnLeft           decimal.Decimal `json:"return_left"` // вернуть на места (P9-07-1)
	OutOfSync            bool            `json:"out_of_sync"` // отгружен и расходится с 1С (P9-08)
}

type pickingPortalFactDTO struct {
	BatchDate   string          `json:"batch_date"`
	CellAddress string          `json:"cell_address"`
	BoxSeq      int             `json:"box_seq"`
	Qty         decimal.Decimal `json:"qty"`
	State       string          `json:"state"`
	PickedBy    string          `json:"picked_by"`
	PickedAt    time.Time       `json:"picked_at"`
	Marks       []string        `json:"marks"`
}

type pickingPortalLineDTO struct {
	ID           string                 `json:"id"`
	LineNo       int                    `json:"line_no"`
	GoodCode     string                 `json:"good_code"`
	GoodName     string                 `json:"good_name"`
	Uom          string                 `json:"uom"`
	CZMarked     bool                   `json:"cz_marked"`
	BatchDate    *string                `json:"batch_date"`
	RegistryCell string                 `json:"registry_cell"`
	CellAddress  string                 `json:"cell_address"`
	PlanQty      int                    `json:"plan_qty"`
	FactQty      decimal.Decimal        `json:"fact_qty"`
	Removed      bool                   `json:"removed"`
	Shortage     bool                   `json:"shortage"`
	Facts        []pickingPortalFactDTO `json:"facts"`
}

type pickingPortalBoxDTO struct {
	Seq       int        `json:"seq"`
	ShippedAt *time.Time `json:"shipped_at"`
}

type pickingPortalChangeDTO struct {
	Kind        string    `json:"kind"`
	GoodCode    string    `json:"good_code"`
	GoodName    string    `json:"good_name"`
	BatchDate   *string   `json:"batch_date"`
	OldQty      *int      `json:"old_qty"`
	NewQty      *int      `json:"new_qty"`
	OrderStatus string    `json:"order_status"`
	At          time.Time `json:"at"`
	Reason      string    `json:"reason"` // откуда правка (P9-08)
}

type pickingPortalEventDTO struct {
	Kind     string           `json:"kind"`
	UserName string           `json:"user_name"`
	PrevName string           `json:"prev_name"`
	Boxes    *int             `json:"boxes"`
	Qty      *decimal.Decimal `json:"qty"`
	At       time.Time        `json:"at"`
}

type pickingPortalDetailDTO struct {
	pickingPortalOrderDTO
	Items   []pickingPortalLineDTO   `json:"items"`
	BoxList []pickingPortalBoxDTO    `json:"box_list"`
	Changes []pickingPortalChangeDTO `json:"changes"`
	Events  []pickingPortalEventDTO  `json:"events"`
}

// Orders: GET /api/v1/picking/portal/orders?date=YYYY-MM-DD[&warehouse=SHB] — заказы склада на
// дату накладной. 200 / 400 (дата) / 404 (склад).
func (h *PickingPortalHandler) Orders(w http.ResponseWriter, r *http.Request) {
	date, ok := pickingDate(w, r)
	if !ok {
		return
	}
	orders, err := h.svc.Orders(r.Context(), pickingWarehouse(r), date)
	if err != nil {
		h.fail(w, r, err, "orders")
		return
	}
	out := make([]pickingPortalOrderDTO, 0, len(orders))
	for _, o := range orders {
		out = append(out, pickingPortalOrderOut(o))
	}
	writeJSON(w, http.StatusOK, out)
}

// Order: GET /api/v1/picking/portal/orders/{id} — окно деталей: строки план/факт с партиями и
// марками, короба, правки реестра. 200 / 404.
func (h *PickingPortalHandler) Order(w http.ResponseWriter, r *http.Request) {
	d, err := h.svc.Order(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		h.fail(w, r, err, "order")
		return
	}
	writeJSON(w, http.StatusOK, pickingPortalDetailOut(d))
}

// Release: POST /api/v1/picking/portal/orders/{id}/release — снять заказ с исполнителя: снова
// «новый», собранное остаётся в коробах. 204 / 404 / 409 (собран или отгружен).
func (h *PickingPortalHandler) Release(w http.ResponseWriter, r *http.Request) {
	leadID, _ := appmw.UserIDFromContext(r.Context())
	if err := h.svc.Release(r.Context(), chi.URLParam(r, "id"), leadID); err != nil {
		h.fail(w, r, err, "release")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ExportXLSX: GET /api/v1/picking/portal/export.xlsx?date=YYYY-MM-DD[&warehouse=SHB] — все
// заказы даты файлом на момент нажатия. 200 (attachment) / 400 / 404.
func (h *PickingPortalHandler) ExportXLSX(w http.ResponseWriter, r *http.Request) {
	date, ok := pickingDate(w, r)
	if !ok {
		return
	}
	data, name, err := h.svc.ExportXLSX(r.Context(), pickingWarehouse(r), date)
	if err != nil {
		h.fail(w, r, err, "export")
		return
	}
	w.Header().Set("Content-Type", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s"`, name))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

// pickingDate — обязательный параметр ?date=YYYY-MM-DD; ошибка — 400 уже отправлен.
func pickingDate(w http.ResponseWriter, r *http.Request) (time.Time, bool) {
	date, err := time.Parse(time.DateOnly, r.URL.Query().Get("date"))
	if err != nil {
		writeError(w, http.StatusBadRequest, "ожидается дата накладной ?date=ГГГГ-ММ-ДД")
		return time.Time{}, false
	}
	return date, true
}

// pickingWarehouse — код склада из ?warehouse=, по умолчанию склад пилота.
func pickingWarehouse(r *http.Request) string {
	if code := strings.TrimSpace(r.URL.Query().Get("warehouse")); code != "" {
		return code
	}
	return defaultWarehouseCode
}

// fail — отказы по состоянию заказа текстом для оператора, остальное — 500.
func (h *PickingPortalHandler) fail(w http.ResponseWriter, r *http.Request, err error, action string) {
	switch {
	case errors.Is(err, repository.ErrNotFound):
		writeError(w, http.StatusNotFound, "склад не найден")
	case errors.Is(err, model.ErrPickingOrderNotFound):
		writeError(w, http.StatusNotFound, err.Error())
	case errors.Is(err, model.ErrPickingOrderClosed):
		writeError(w, http.StatusConflict, err.Error())
	default:
		slog.ErrorContext(r.Context(), "picking portal failed", "action", action, "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
	}
}

// dateOnly — дата для JSON: ГГГГ-ММ-ДД, nil остаётся nil.
func dateOnly(t *time.Time) *string {
	if t == nil {
		return nil
	}
	s := t.Format(time.DateOnly)
	return &s
}

func pickingPortalOrderOut(o model.PickingPortalOrder) pickingPortalOrderDTO {
	return pickingPortalOrderDTO{
		ID: o.ID, Number: o.Number, RegistryDate: o.RegistryDate.Format(time.DateOnly),
		InvoiceNumber: o.InvoiceNumber, OrderNumber: o.OrderNumber, OrderDate: dateOnly(o.OrderDate),
		Direction: o.Direction, Client: o.Client, Address: o.Address, Status: o.Status,
		IsPartial: o.IsPartial, HasUnknown: o.HasUnknown, Deleted: o.Deleted,
		ChangedAfterShipment: o.ChangedAfterShipment, AssigneeName: o.AssigneeName, TakenAt: o.TakenAt,
		PickedByName: o.PickedByName, PickedAt: o.PickedAt, ShippedAt: o.ShippedAt,
		Lines: o.Lines, PlanQty: o.PlanQty, FactQty: o.FactQty, Boxes: o.Boxes, ReturnLeft: o.ReturnLeft,
		OutOfSync: o.OutOfSync,
	}
}

func pickingPortalDetailOut(d model.PickingPortalDetail) pickingPortalDetailDTO {
	out := pickingPortalDetailDTO{
		pickingPortalOrderDTO: pickingPortalOrderOut(d.Order),
		Items:                 make([]pickingPortalLineDTO, 0, len(d.Lines)),
		BoxList:               make([]pickingPortalBoxDTO, 0, len(d.Boxes)),
		Changes:               make([]pickingPortalChangeDTO, 0, len(d.Changes)),
		Events:                make([]pickingPortalEventDTO, 0, len(d.Events)),
	}
	for _, e := range d.Events {
		out.Events = append(out.Events, pickingPortalEventDTO(e))
	}
	for _, l := range d.Lines {
		facts := make([]pickingPortalFactDTO, 0, len(l.Facts))
		for _, f := range l.Facts {
			marks := f.Marks
			if marks == nil {
				marks = []string{}
			}
			facts = append(facts, pickingPortalFactDTO{
				BatchDate: f.BatchDate.Format(time.DateOnly), CellAddress: f.CellAddress, BoxSeq: f.BoxSeq,
				Qty: f.Qty, State: f.State, PickedBy: f.PickedBy, PickedAt: f.PickedAt, Marks: marks,
			})
		}
		out.Items = append(out.Items, pickingPortalLineDTO{
			ID: l.ID, LineNo: l.LineNo, GoodCode: l.GoodCode, GoodName: l.GoodName, Uom: l.Uom,
			CZMarked: l.CZMarked, BatchDate: dateOnly(l.BatchDate), RegistryCell: l.RegistryCell,
			CellAddress: l.CellAddress, PlanQty: l.PlanQty, FactQty: l.FactQty(),
			Removed: l.Removed, Shortage: l.Shortage, Facts: facts,
		})
	}
	for _, b := range d.Boxes {
		out.BoxList = append(out.BoxList, pickingPortalBoxDTO(b))
	}
	for _, c := range d.Changes {
		out.Changes = append(out.Changes, pickingPortalChangeDTO{
			Kind: c.Kind, GoodCode: c.GoodCode, GoodName: c.GoodName, BatchDate: dateOnly(c.BatchDate),
			OldQty: c.OldQty, NewQty: c.NewQty, OrderStatus: c.OrderStatus, At: c.At, Reason: c.Reason,
		})
	}
	return out
}
