package handler

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/service"
)

// contentsReader — то, что ручкам просмотра нужно от сервиса. Узкий интерфейс, а не
// конкретный сервис: транспорт зависит от абстракции (dev.md §2).
type contentsReader interface {
	Snapshot(ctx context.Context) (model.ContentsSnapshot, error)
	CellContents(ctx context.Context, cellID string) (model.CellContents, error)
	LoadUnitCard(ctx context.Context, id string) (model.LoadUnitCard, error)
	SearchLoadUnits(ctx context.Context, code string) ([]model.LoadUnitCard, error)
	LoadUnitHistory(ctx context.Context, id string) (model.LoadUnitHistory, error)
	LoadUnitByCZCode(ctx context.Context, code string) (model.LoadUnitCard, error)
}

// ContentsHandler — просмотр содержимого ячеек и коробов на ТСД (P5-05).
type ContentsHandler struct {
	svc contentsReader
}

// NewContentsHandler создаёт хендлер просмотра содержимого.
func NewContentsHandler(svc contentsReader) *ContentsHandler {
	return &ContentsHandler{svc: svc}
}

// contentLineResponse — строка содержимого для показа человеку: с наименованием товара.
type contentLineResponse struct {
	GoodID         string          `json:"good_id"`
	GoodCode       string          `json:"good_code"`
	GoodName       string          `json:"good_name"`
	Uom            string          `json:"uom"`
	BatchID        string          `json:"batch_id"`
	ProductionDate string          `json:"production_date"`
	Qty            decimal.Decimal `json:"qty"`
}

type loadUnitCardResponse struct {
	ID          string                `json:"id"`
	Kind        string                `json:"kind"`
	Status      string                `json:"status"`
	CellID      *string               `json:"cell_id"`
	CellAddress *string               `json:"cell_address"`
	CreatedAt   string                `json:"created_at"` // RFC3339
	Live        bool                  `json:"live"`
	Contents    []contentLineResponse `json:"contents"`
	// Склад короба целиком (P6-07-1): товар кладётся в короб только того же склада.
	InternalWarehouseID string `json:"internal_warehouse_id"`
	// Короб ЧЗ (CZ-06): код `00`+SSCC — по нему короб находят сканом этикетки ЧЗ; null —
	// свой короб с QR. cz_opened — из короба ЧЗ вынута хоть одна марка.
	CZCode   *string `json:"cz_code"`
	CZOpened bool    `json:"cz_opened"`
}

type looseLineResponse struct {
	InternalWarehouseID string `json:"internal_warehouse_id"`
	contentLineResponse
}

type cellContentsResponse struct {
	CellID      string                 `json:"cell_id"`
	Address     string                 `json:"address"`
	WarehouseID string                 `json:"warehouse_id"`
	LoadUnits   []loadUnitCardResponse `json:"load_units"`
	Loose       []looseLineResponse    `json:"loose"`
}

// Снимок для кэша — без наименований: ТСД берёт их из своего справочника товаров, который
// грузится в тот же заход. Так ответ на весь склад вдвое меньше.
type snapshotLineResponse struct {
	GoodID         string          `json:"good_id"`
	BatchID        string          `json:"batch_id"`
	ProductionDate string          `json:"production_date"`
	Qty            decimal.Decimal `json:"qty"`
}

type snapshotLoadUnitResponse struct {
	ID        string                 `json:"id"`
	Kind      string                 `json:"kind"`
	CellID    string                 `json:"cell_id"`
	CreatedAt string                 `json:"created_at"` // RFC3339
	Contents  []snapshotLineResponse `json:"contents"`
	// Склад короба целиком (P6-07-1).
	InternalWarehouseID string `json:"internal_warehouse_id"`
	// Короб ЧЗ (CZ-06): ТСД узнаёт его по скану SSCC без связи. Поля — только у короба ЧЗ.
	CZCode   *string `json:"cz_code,omitempty"`
	CZOpened bool    `json:"cz_opened,omitempty"`
}

type snapshotLooseResponse struct {
	CellID              string `json:"cell_id"`
	InternalWarehouseID string `json:"internal_warehouse_id"`
	snapshotLineResponse
}

// snapshotMarkResponse — марка ЧЗ на складе (CZ-06): в коробе (load_unit_id) или россыпью
// (cell_id + internal_warehouse_id). aggregate_code — упаковка ЧЗ, в которой марка пришла.
type snapshotMarkResponse struct {
	CIS                 string  `json:"cis"`
	GoodID              string  `json:"good_id"`
	BatchID             string  `json:"batch_id"`
	ProductionDate      string  `json:"production_date"`
	LoadUnitID          *string `json:"load_unit_id,omitempty"`
	CellID              *string `json:"cell_id,omitempty"`
	InternalWarehouseID *string `json:"internal_warehouse_id,omitempty"`
	AggregateCode       *string `json:"aggregate_code,omitempty"`
}

type snapshotResponse struct {
	AsOf      string                     `json:"as_of"` // RFC3339
	LoadUnits []snapshotLoadUnitResponse `json:"load_units"`
	Loose     []snapshotLooseResponse    `json:"loose"`
	Marks     []snapshotMarkResponse     `json:"marks"`
}

// Snapshot: GET /api/v1/contents/snapshot — все живые короба и россыпь для кэша ТСД. 200.
func (h *ContentsHandler) Snapshot(w http.ResponseWriter, r *http.Request) {
	snap, err := h.svc.Snapshot(r.Context())
	if err != nil {
		contentsError(w, r, err)
		return
	}
	out := snapshotResponse{
		AsOf:      snap.AsOf.UTC().Format(time.RFC3339),
		LoadUnits: make([]snapshotLoadUnitResponse, 0, len(snap.LoadUnits)),
		Loose:     make([]snapshotLooseResponse, 0, len(snap.Loose)),
		Marks:     make([]snapshotMarkResponse, 0, len(snap.Marks)),
	}
	for _, lu := range snap.LoadUnits {
		// У живого короба ячейка есть всегда — это часть определения живости.
		var cellID string
		if lu.CellID != nil {
			cellID = *lu.CellID
		}
		item := snapshotLoadUnitResponse{
			ID: lu.ID, Kind: lu.Kind, CellID: cellID,
			CreatedAt:           lu.CreatedAt.UTC().Format(time.RFC3339),
			InternalWarehouseID: lu.InternalWarehouseID,
			CZCode:              lu.CZCode,
			CZOpened:            lu.CZOpened,
			Contents:            make([]snapshotLineResponse, 0, len(lu.Contents)),
		}
		for _, c := range lu.Contents {
			item.Contents = append(item.Contents, toSnapshotLine(c))
		}
		out.LoadUnits = append(out.LoadUnits, item)
	}
	for _, l := range snap.Loose {
		out.Loose = append(out.Loose, snapshotLooseResponse{
			CellID: l.CellID, InternalWarehouseID: l.InternalWarehouseID,
			snapshotLineResponse: toSnapshotLine(l.ContentLine),
		})
	}
	for _, m := range snap.Marks {
		out.Marks = append(out.Marks, snapshotMarkResponse{
			CIS: m.CIS, GoodID: m.GoodID, BatchID: m.BatchID,
			ProductionDate:      m.ProductionDate.Format(productionDateLayout),
			LoadUnitID:          m.LoadUnitID,
			CellID:              m.CellID,
			InternalWarehouseID: m.InternalWarehouseID,
			AggregateCode:       m.AggregateCode,
		})
	}
	writeJSON(w, http.StatusOK, out)
}

// CellContents: GET /api/v1/cells/{id}/contents — короба и россыпь ячейки. 200 / 400 / 404.
func (h *ContentsHandler) CellContents(w http.ResponseWriter, r *http.Request) {
	cell, err := h.svc.CellContents(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		contentsError(w, r, err)
		return
	}
	out := cellContentsResponse{
		CellID: cell.CellID, Address: cell.Address, WarehouseID: cell.WarehouseID,
		LoadUnits: make([]loadUnitCardResponse, 0, len(cell.LoadUnits)),
		Loose:     make([]looseLineResponse, 0, len(cell.Loose)),
	}
	for _, lu := range cell.LoadUnits {
		out.LoadUnits = append(out.LoadUnits, toLoadUnitCard(lu))
	}
	for _, l := range cell.Loose {
		out.Loose = append(out.Loose, looseLineResponse{
			InternalWarehouseID: l.InternalWarehouseID,
			contentLineResponse: toContentLine(l.ContentLine),
		})
	}
	writeJSON(w, http.StatusOK, out)
}

// LoadUnitCard: GET /api/v1/load-units/{id}/card — карточка короба, в том числе неживого.
// 200 / 400 / 404.
func (h *ContentsHandler) LoadUnitCard(w http.ResponseWriter, r *http.Request) {
	card, err := h.svc.LoadUnitCard(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		contentsError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, toLoadUnitCard(card))
}

// LoadUnitByCZCode: GET /api/v1/load-units/cz/{code} — карточка ГЕ короба ЧЗ по коду
// `00`+SSCC с его этикетки (CZ-06). 200 / 400 / 404 (короб не принят).
func (h *ContentsHandler) LoadUnitByCZCode(w http.ResponseWriter, r *http.Request) {
	card, err := h.svc.LoadUnitByCZCode(r.Context(), chi.URLParam(r, "code"))
	if err != nil {
		contentsError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, toLoadUnitCard(card))
}

// SearchLoadUnits: GET /api/v1/load-units?code=… — короба по короткому коду с ярлыка,
// живые и нет (P5-05-1). 200 (список, возможно пустой) / 400.
func (h *ContentsHandler) SearchLoadUnits(w http.ResponseWriter, r *http.Request) {
	found, err := h.svc.SearchLoadUnits(r.Context(), r.URL.Query().Get("code"))
	if err != nil {
		contentsError(w, r, err)
		return
	}
	out := make([]loadUnitCardResponse, 0, len(found))
	for _, lu := range found {
		out = append(out, toLoadUnitCard(lu))
	}
	writeJSON(w, http.StatusOK, out)
}

type loadUnitReceiptResponse struct {
	ReceiptID  string  `json:"receipt_id"`
	Number     int64   `json:"number"`     // номер приёмки, «ПР» (ADHOC-55)
	DocNumber  string  `json:"doc_number"` // накладная поставщика (ADHOC-23)
	DocDate    string  `json:"doc_date"`   // DD-MM-YYYY
	ReceivedBy string  `json:"received_by"`
	Supplier   *string `json:"supplier"`
	PostedAt   *string `json:"posted_at"` // RFC3339; null — не оприходован
}

type loadUnitMoveResponse struct {
	From     *string `json:"from"` // null — первое размещение
	To       string  `json:"to"`
	Source   string  `json:"source"` // receipt | putaway
	UserName *string `json:"user_name"`
	At       string  `json:"at"` // RFC3339
	// Операция и её номер (ADHOC-55): receipt | putaway | move | replenish | stocktake;
	// пусто и 0 — операция без номера.
	Operation       string `json:"operation"`
	OperationNumber int64  `json:"operation_number"`
}

// loadUnitContentEventResponse — изменение состава короба (ADHOC-32): kind — in | out | problem
// | write_off | return; peer — ячейка на той стороне (null у списания и отгрузки).
type loadUnitContentEventResponse struct {
	Kind           string          `json:"kind"`
	GoodName       string          `json:"good_name"`
	Uom            string          `json:"uom"`
	ProductionDate string          `json:"production_date"` // DD-MM-YYYY
	Qty            decimal.Decimal `json:"qty"`
	Peer           *string         `json:"peer"`
	PeerLoadUnitID *string         `json:"peer_load_unit_id"`
	UserName       *string         `json:"user_name"`
	At             string          `json:"at"` // RFC3339
}

type loadUnitHistoryResponse struct {
	LoadUnitID string                         `json:"load_unit_id"`
	CreatedAt  string                         `json:"created_at"` // RFC3339
	Receipt    *loadUnitReceiptResponse       `json:"receipt"`
	Moves      []loadUnitMoveResponse         `json:"moves"`
	Contents   []loadUnitContentEventResponse `json:"contents"`
}

// LoadUnitHistory: GET /api/v1/load-units/{id}/history — приёмка, переносы короба и изменения
// его состава (P5-05-1, ADHOC-32).
// 200 / 400 / 404.
func (h *ContentsHandler) LoadUnitHistory(w http.ResponseWriter, r *http.Request) {
	hist, err := h.svc.LoadUnitHistory(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		contentsError(w, r, err)
		return
	}
	out := loadUnitHistoryResponse{
		LoadUnitID: hist.LoadUnitID,
		CreatedAt:  hist.CreatedAt.UTC().Format(time.RFC3339),
		Moves:      make([]loadUnitMoveResponse, 0, len(hist.Moves)),
		Contents:   make([]loadUnitContentEventResponse, 0, len(hist.Contents)),
	}
	for _, c := range hist.Contents {
		out.Contents = append(out.Contents, loadUnitContentEventResponse{
			Kind: c.Kind, GoodName: c.GoodName, Uom: c.Uom,
			ProductionDate: c.ProductionDate.Format(productionDateLayout), Qty: c.Qty,
			Peer: c.PeerAddress, PeerLoadUnitID: c.PeerLoadUnitID, UserName: c.UserName,
			At: c.At.UTC().Format(time.RFC3339),
		})
	}
	if rc := hist.Receipt; rc != nil {
		out.Receipt = &loadUnitReceiptResponse{
			ReceiptID: rc.ReceiptID, Number: rc.Number, ReceivedBy: rc.ReceivedBy, Supplier: rc.SupplierName,
			DocNumber: rc.Doc.Number, DocDate: rc.Doc.Date.Format(productionDateLayout),
		}
		if rc.PostedAt != nil {
			at := rc.PostedAt.UTC().Format(time.RFC3339)
			out.Receipt.PostedAt = &at
		}
	}
	for _, m := range hist.Moves {
		out.Moves = append(out.Moves, loadUnitMoveResponse{
			From: m.FromAddress, To: m.ToAddress, Source: m.Source, UserName: m.UserName,
			At: m.At.UTC().Format(time.RFC3339), Operation: m.Operation, OperationNumber: m.OperationNumber,
		})
	}
	writeJSON(w, http.StatusOK, out)
}

func toLoadUnitCard(lu model.LoadUnitCard) loadUnitCardResponse {
	out := loadUnitCardResponse{
		ID: lu.ID, Kind: lu.Kind, Status: lu.Status,
		CellID: lu.CellID, CellAddress: lu.CellAddress,
		CreatedAt: lu.CreatedAt.UTC().Format(time.RFC3339),
		Live:      lu.Live,
		Contents:  make([]contentLineResponse, 0, len(lu.Contents)),

		InternalWarehouseID: lu.InternalWarehouseID,
		CZCode:              lu.CZCode,
		CZOpened:            lu.CZOpened,
	}
	for _, c := range lu.Contents {
		out.Contents = append(out.Contents, toContentLine(c))
	}
	return out
}

func toContentLine(c model.ContentLine) contentLineResponse {
	return contentLineResponse{
		GoodID: c.GoodID, GoodCode: c.GoodCode, GoodName: c.GoodName, Uom: c.Uom,
		BatchID: c.BatchID, ProductionDate: c.ProductionDate.Format(productionDateLayout), Qty: c.Qty,
	}
}

func toSnapshotLine(c model.ContentLine) snapshotLineResponse {
	return snapshotLineResponse{
		GoodID: c.GoodID, BatchID: c.BatchID,
		ProductionDate: c.ProductionDate.Format(productionDateLayout), Qty: c.Qty,
	}
}

// contentsError маппит ошибки просмотра в HTTP-коды: 400 — кривой идентификатор,
// 404 — отсканированного нет, остальное — 500.
func contentsError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, service.ErrInvalidCellID), errors.Is(err, service.ErrInvalidLoadUnitID),
		errors.Is(err, service.ErrInvalidShortCode), errors.Is(err, service.ErrInvalidCZBoxCode):
		writeError(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, model.ErrCellNotFound), errors.Is(err, model.ErrLoadUnitNotFound):
		writeError(w, http.StatusNotFound, err.Error())
	default:
		slog.ErrorContext(r.Context(), "contents failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
	}
}
