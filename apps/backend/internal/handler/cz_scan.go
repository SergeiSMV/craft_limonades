package handler

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"craftwms/internal/model"
)

// czScanResponse — ответ `POST /api/v1/cz/scan`: всё, что ТСД показывает по скану марки или
// кода короба. Формат закреплён эталонами testdata/cz_scan_mark.json и cz_scan_box.json —
// их же разбирает клиент.
type czScanResponse struct {
	Code string `json:"code"`
	// Kind — вид кода по ЧЗ: UNIT — марка единицы, GROUP — групповая упаковка, BOX — короб.
	Kind string     `json:"kind"`
	CZ   czScanInfo `json:"cz"`
	// Good — товар справочника по GTIN; null — GTIN незнаком, тогда BindBarcode — какой ШК
	// предложить привязать (EAN-13).
	Good        *czGoodResponse `json:"good"`
	BindBarcode string          `json:"bind_barcode,omitempty"`
	// Mark — марка в WMS; null — не числится. LoadUnitID — принятый короб ЧЗ (ГЕ).
	Mark       *czMarkResponse `json:"mark"`
	LoadUnitID string          `json:"load_unit_id,omitempty"`
	// Discrepancy — расхождение с ЧЗ (CZ-05): foreign_mark / retired; нет — поля нет.
	Discrepancy string                      `json:"discrepancy,omitempty"`
	Composition []czCompositionLineResponse `json:"composition"`
	Units       int                         `json:"units"`
	Unreadable  []string                    `json:"unreadable"`
	// Groups — групповые упаковки внутри (CZ-05), Parents — КИ единицы → её упаковка:
	// приёмка заводит из них агрегаты и aggregate_code марок.
	Groups  []czGroupResponse `json:"groups"`
	Parents map[string]string `json:"parents"`
}

// czScanInfo — данные ЧЗ по коду; даты — днём (YYYY-MM-DD), время ЧЗ складу не нужно.
type czScanInfo struct {
	ProductName    string `json:"product_name,omitempty"`
	Gtin           string `json:"gtin,omitempty"`
	ProductGroup   string `json:"product_group,omitempty"`
	Status         string `json:"status,omitempty"`
	OwnerInn       string `json:"owner_inn,omitempty"`
	OwnerName      string `json:"owner_name,omitempty"`
	ProducedDate   string `json:"produced_date,omitempty"`
	ExpirationDate string `json:"expiration_date,omitempty"`
	Parent         string `json:"parent,omitempty"`
}

type czGoodResponse struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// czMarkResponse — что о марке знает WMS: история марки в CZ-04 — приход и текущее место.
type czMarkResponse struct {
	Status              string `json:"status"`
	LoadUnitID          string `json:"load_unit_id,omitempty"`
	LoadUnitCellID      string `json:"load_unit_cell_id,omitempty"`
	CellID              string `json:"cell_id,omitempty"`
	InternalWarehouseID string `json:"internal_warehouse_id,omitempty"`
	AggregateCode       string `json:"aggregate_code,omitempty"`
	// CellAddress — адрес ячейки, где марка лежит (короба или своей); пусто — нет места.
	CellAddress string    `json:"cell_address,omitempty"`
	ReceivedAt  time.Time `json:"received_at"`
}

type czCompositionLineResponse struct {
	Gtin         string          `json:"gtin"`
	ProductName  string          `json:"product_name"`
	Good         *czGoodResponse `json:"good"`
	ProducedDate string          `json:"produced_date"`
	Count        int             `json:"count"`
	CIS          []string        `json:"cis"`
	Discrepancy  string          `json:"discrepancy,omitempty"`
}

// Scan: POST /api/v1/cz/scan {code} — скан марки или кода короба (CZ-04).
//
// Код — как со сканера: префикс AIM и криптохвост сервис срежет сам. Код в теле, а не в пути:
// в КИ бывают `/`, `%`, `"`. Только онлайн — ЧЗ без связи не читается.
func (h *CZHandler) Scan(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Code string `json:"code"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, czMaxBody)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "ожидается {\"code\": \"…\"}")
		return
	}
	res, err := h.svc.Scan(r.Context(), req.Code)
	if err != nil {
		code, msg := czErrorResponse(err)
		if code >= http.StatusInternalServerError {
			slog.ErrorContext(r.Context(), "chestny znak scan failed", "error", err)
		}
		writeError(w, code, msg)
		return
	}
	writeJSON(w, http.StatusOK, toCZScanResponse(res))
}

// toCZScanResponse переводит результат скана в ответ ТСД.
func toCZScanResponse(s model.CZScan) czScanResponse {
	kind := s.Info.PackageType
	if kind == "" {
		kind = "UNIT"
	}
	out := czScanResponse{
		Code: s.Code,
		Kind: kind,
		CZ: czScanInfo{
			ProductName:    s.Info.ProductName,
			Gtin:           s.Info.Gtin,
			ProductGroup:   s.Info.ProductGroup,
			Status:         s.Info.Status,
			OwnerInn:       s.Info.OwnerInn,
			OwnerName:      s.Info.OwnerName,
			ProducedDate:   czDay(s.Info.ProducedDate),
			ExpirationDate: czDay(s.Info.ExpirationDate),
			Parent:         s.Info.Parent,
		},
		Good:        toCZGood(s.Good),
		BindBarcode: s.BindBarcode,
		Discrepancy: s.Discrepancy,
		LoadUnitID:  s.LoadUnitID,
		Composition: make([]czCompositionLineResponse, 0, len(s.Composition)),
		Units:       s.Units,
		Unreadable:  s.Unreadable,
	}
	if out.Unreadable == nil {
		out.Unreadable = []string{}
	}
	out.Groups = make([]czGroupResponse, 0, len(s.Groups))
	for _, g := range s.Groups {
		out.Groups = append(out.Groups, czGroupResponse{Code: g.Code, ParentCode: g.ParentCode})
	}
	out.Parents = s.Parents
	if out.Parents == nil {
		out.Parents = map[string]string{}
	}
	if m := s.Mark; m != nil {
		out.Mark = &czMarkResponse{
			Status: m.Status, LoadUnitID: m.LoadUnitID, LoadUnitCellID: m.LoadUnitCellID,
			CellID: m.CellID, InternalWarehouseID: m.InternalWarehouseID,
			AggregateCode: m.AggregateCode, CellAddress: m.CellAddress, ReceivedAt: m.ReceivedAt.UTC(),
		}
	}
	for _, ln := range s.Composition {
		out.Composition = append(out.Composition, czCompositionLineResponse{
			Gtin: ln.GTIN, ProductName: ln.ProductName, Good: toCZGood(ln.Good),
			ProducedDate: ln.ProducedDate, Count: ln.Count, CIS: ln.CIS, Discrepancy: ln.Discrepancy,
		})
	}
	return out
}

// czGroupResponse — групповая упаковка внутри сканированной (CZ-05).
type czGroupResponse struct {
	Code       string `json:"code"`
	ParentCode string `json:"parent_code"`
}

func toCZGood(g *model.CZGoodRef) *czGoodResponse {
	if g == nil {
		return nil
	}
	return &czGoodResponse{ID: g.ID, Name: g.Name}
}

// czDay — дата из метки времени ЧЗ (`2026-10-12T00:00:00.000Z` → `2026-10-12`).
func czDay(ts string) string {
	if len(ts) >= 10 {
		return ts[:10]
	}
	return ts
}
