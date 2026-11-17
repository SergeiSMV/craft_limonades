package handler

import (
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"strings"

	"github.com/go-chi/chi/v5"

	"craftwms/internal/repository"
	"craftwms/internal/service"
)

// CatalogHandler - HTTP-обработчики чтения справочников (P1-06): товары, группы, поставщики, ячейки, остатки.
type CatalogHandler struct {
	svc *service.CatalogService
}

// NewCatalogHandler создаёт обработчик каталога.
func NewCatalogHandler(svc *service.CatalogService) *CatalogHandler {
	return &CatalogHandler{svc: svc}
}

// ListGoods: GET /api/v1/goods - поиск товаров (q, group_id, supplier_id) с пагинацией (limit/offset).
func (h *CatalogHandler) ListGoods(w http.ResponseWriter, r *http.Request) {
	limit, offset := paging(r)
	page, err := h.svc.ListGoods(r.Context(), service.GoodsQuery{
		Query:      queryStr(r, "q"),
		GroupID:    optStr(r, "group_id"),
		SupplierID: optStr(r, "supplier_id"),
		Limit:      limit, Offset: offset,
	})
	if err != nil {
		catalogError(w, r, "list goods", err)
		return
	}
	writeJSON(w, http.StatusOK, page)
}

// GetGood: GET /api/v1/goods/{id} - один товар (404, если не найден).
func (h *CatalogHandler) GetGood(w http.ResponseWriter, r *http.Request) {
	good, err := h.svc.GetGood(r.Context(), chi.URLParam(r, "id"))
	if errors.Is(err, repository.ErrNotFound) {
		writeError(w, http.StatusNotFound, "товар не найден")
		return
	}
	if err != nil {
		catalogError(w, r, "get good", err)
		return
	}
	writeJSON(w, http.StatusOK, good)
}

// ListGroups: GET /api/v1/nomenclature-groups - все группы номенклатуры (клиент строит дерево).
func (h *CatalogHandler) ListGroups(w http.ResponseWriter, r *http.Request) {
	groups, err := h.svc.ListGroups(r.Context())
	if err != nil {
		catalogError(w, r, "list groups", err)
		return
	}
	writeJSON(w, http.StatusOK, groups)
}

// ListSuppliers: GET /api/v1/suppliers - поставщики (опциональный поиск q).
func (h *CatalogHandler) ListSuppliers(w http.ResponseWriter, r *http.Request) {
	suppliers, err := h.svc.ListSuppliers(r.Context(), queryStr(r, "q"))
	if err != nil {
		catalogError(w, r, "list suppliers", err)
		return
	}
	writeJSON(w, http.StatusOK, suppliers)
}

// ListCells: GET /api/v1/cells - поиск ячеек (q по адресу, warehouse_id, is_floor) с пагинацией.
func (h *CatalogHandler) ListCells(w http.ResponseWriter, r *http.Request) {
	limit, offset := paging(r)
	page, err := h.svc.ListCells(r.Context(), service.CellsQuery{
		Query:       queryStr(r, "q"),
		WarehouseID: optStr(r, "warehouse_id"),
		IsFloor:     optBool(r, "is_floor"),
		Limit:       limit, Offset: offset,
	})
	if err != nil {
		catalogError(w, r, "list cells", err)
		return
	}
	writeJSON(w, http.StatusOK, page)
}

// ListStock: GET /api/v1/stock - остатки (good_id - «где лежит товар», cell_id - «что в ячейке») с пагинацией.
func (h *CatalogHandler) ListStock(w http.ResponseWriter, r *http.Request) {
	limit, offset := paging(r)
	page, err := h.svc.ListStock(r.Context(), service.StockQuery{
		GoodID: optStr(r, "good_id"),
		CellID: optStr(r, "cell_id"),
		Limit:  limit, Offset: offset,
	})
	if err != nil {
		catalogError(w, r, "list stock", err)
		return
	}
	writeJSON(w, http.StatusOK, page)
}

// catalogError логирует и отдаёт 500 (внутренние ошибки чтения не про ввод клиента).
func catalogError(w http.ResponseWriter, r *http.Request, op string, err error) {
	slog.ErrorContext(r.Context(), "catalog read failed", "op", op, "error", err)
	writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
}

// --- разбор query-параметров ---

// queryStr - обрезанное значение параметра ("" если нет).
func queryStr(r *http.Request, key string) string {
	return strings.TrimSpace(r.URL.Query().Get(key))
}

// optStr - указатель на значение параметра или nil (нет фильтра), если параметр пуст.
func optStr(r *http.Request, key string) *string {
	if v := queryStr(r, key); v != "" {
		return &v
	}
	return nil
}

// optBool - *bool из параметра (true/false/1/0), nil для пустого/нераспознанного (нет фильтра).
func optBool(r *http.Request, key string) *bool {
	switch strings.ToLower(queryStr(r, key)) {
	case "true", "1":
		v := true
		return &v
	case "false", "0":
		v := false
		return &v
	default:
		return nil
	}
}

// paging - limit/offset из query (пустые/кривые → 0, дальше сервис приведёт к дефолтам/границам).
func paging(r *http.Request) (limit, offset int) {
	limit, _ = strconv.Atoi(queryStr(r, "limit"))
	offset, _ = strconv.Atoi(queryStr(r, "offset"))
	return limit, offset
}
