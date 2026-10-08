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
}

type snapshotLooseResponse struct {
	CellID              string `json:"cell_id"`
	InternalWarehouseID string `json:"internal_warehouse_id"`
	snapshotLineResponse
}

type snapshotResponse struct {
	AsOf      string                     `json:"as_of"` // RFC3339
	LoadUnits []snapshotLoadUnitResponse `json:"load_units"`
	Loose     []snapshotLooseResponse    `json:"loose"`
}

// Snapshot: GET /api/v1/contents/snapshot — все живые короба и россыпь для кэша ТСД. 200.
func (h *ContentsHandler) Snapshot(w http.ResponseWriter, r *http.Request) {
	snap, err := h.svc.Snapshot(r.Context())
	if err != nil {
		contentsError(w, err)
		return
	}
	out := snapshotResponse{
		AsOf:      snap.AsOf.UTC().Format(time.RFC3339),
		LoadUnits: make([]snapshotLoadUnitResponse, 0, len(snap.LoadUnits)),
		Loose:     make([]snapshotLooseResponse, 0, len(snap.Loose)),
	}
	for _, lu := range snap.LoadUnits {
		// У живого короба ячейка есть всегда — это часть определения живости.
		var cellID string
		if lu.CellID != nil {
			cellID = *lu.CellID
		}
		item := snapshotLoadUnitResponse{
			ID: lu.ID, Kind: lu.Kind, CellID: cellID,
			CreatedAt: lu.CreatedAt.UTC().Format(time.RFC3339),
			Contents:  make([]snapshotLineResponse, 0, len(lu.Contents)),
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
	writeJSON(w, http.StatusOK, out)
}

// CellContents: GET /api/v1/cells/{id}/contents — короба и россыпь ячейки. 200 / 400 / 404.
func (h *ContentsHandler) CellContents(w http.ResponseWriter, r *http.Request) {
	cell, err := h.svc.CellContents(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		contentsError(w, err)
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
		contentsError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, toLoadUnitCard(card))
}

func toLoadUnitCard(lu model.LoadUnitCard) loadUnitCardResponse {
	out := loadUnitCardResponse{
		ID: lu.ID, Kind: lu.Kind, Status: lu.Status,
		CellID: lu.CellID, CellAddress: lu.CellAddress,
		CreatedAt: lu.CreatedAt.UTC().Format(time.RFC3339),
		Live:      lu.Live,
		Contents:  make([]contentLineResponse, 0, len(lu.Contents)),
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
func contentsError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, service.ErrInvalidCellID), errors.Is(err, service.ErrInvalidLoadUnitID):
		writeError(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, model.ErrCellNotFound), errors.Is(err, model.ErrLoadUnitNotFound):
		writeError(w, http.StatusNotFound, err.Error())
	default:
		slog.Error("contents failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
	}
}
