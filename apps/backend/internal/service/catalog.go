package service

import (
	"context"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// Пагинация: дефолт и потолок limit. Потолок защищает от «выгрузи всё» одним запросом.
const (
	defaultLimit = 50
	maxLimit     = 200
)

// Page — страница списка для выдачи клиенту. Items всегда непустой слайс (в JSON — [], не null).
type Page[T any] struct {
	Items  []T `json:"items"`
	Total  int `json:"total"`
	Limit  int `json:"limit"`
	Offset int `json:"offset"`
}

// Репозитории чтения, нужные каталогу (зависимость от интерфейсов, а не реализаций).
type (
	goodsReadRepo interface {
		List(ctx context.Context, f repository.GoodsFilter) ([]model.Good, int, error)
		GetByID(ctx context.Context, id string) (model.Good, error)
	}
	groupReadRepo interface {
		List(ctx context.Context) ([]model.NomenclatureGroup, error)
	}
	supplierReadRepo interface {
		List(ctx context.Context, query string) ([]model.Supplier, error)
	}
	cellReadRepo interface {
		List(ctx context.Context, f repository.CellsFilter) ([]model.Cell, int, error)
	}
	stockReadRepo interface {
		List(ctx context.Context, f repository.StockFilter) ([]model.StockItem, int, error)
	}
)

// CatalogService — чтение справочников (товары, группы, поставщики, ячейки, остатки).
type CatalogService struct {
	goods     goodsReadRepo
	groups    groupReadRepo
	suppliers supplierReadRepo
	cells     cellReadRepo
	stock     stockReadRepo
}

// NewCatalogService собирает сервис чтения справочников.
func NewCatalogService(goods goodsReadRepo, groups groupReadRepo, suppliers supplierReadRepo, cells cellReadRepo, stock stockReadRepo) *CatalogService {
	return &CatalogService{goods: goods, groups: groups, suppliers: suppliers, cells: cells, stock: stock}
}

// clampPaging приводит limit/offset к безопасным границам: limit ∈ [1, maxLimit] (0 → дефолт),
// offset ≥ 0. Валидация — в сервисе (бизнес-правило), а не размазана по хендлерам.
func clampPaging(limit, offset int) (int, int) {
	switch {
	case limit <= 0:
		limit = defaultLimit
	case limit > maxLimit:
		limit = maxLimit
	}
	if offset < 0 {
		offset = 0
	}
	return limit, offset
}

// GoodsQuery — входные параметры поиска товаров (из хендлера).
type GoodsQuery struct {
	Query      string
	GroupID    *string
	SupplierID *string
	Limit      int
	Offset     int
}

// ListGoods — страница товаров под фильтр.
func (s *CatalogService) ListGoods(ctx context.Context, q GoodsQuery) (Page[model.Good], error) {
	limit, offset := clampPaging(q.Limit, q.Offset)
	items, total, err := s.goods.List(ctx, repository.GoodsFilter{
		Query: q.Query, GroupID: q.GroupID, SupplierID: q.SupplierID, Limit: limit, Offset: offset,
	})
	if err != nil {
		return Page[model.Good]{}, err
	}
	return Page[model.Good]{Items: items, Total: total, Limit: limit, Offset: offset}, nil
}

// GetGood — один товар по id (repository.ErrNotFound, если нет).
func (s *CatalogService) GetGood(ctx context.Context, id string) (model.Good, error) {
	return s.goods.GetByID(ctx, id)
}

// ListGroups — все группы номенклатуры (клиент строит дерево).
func (s *CatalogService) ListGroups(ctx context.Context) ([]model.NomenclatureGroup, error) {
	return s.groups.List(ctx)
}

// ListSuppliers — поставщики (опциональный поиск по подстроке имени).
func (s *CatalogService) ListSuppliers(ctx context.Context, query string) ([]model.Supplier, error) {
	return s.suppliers.List(ctx, query)
}

// CellsQuery — входные параметры поиска ячеек.
type CellsQuery struct {
	Query       string
	WarehouseID *string
	IsFloor     *bool
	Limit       int
	Offset      int
}

// ListCells — страница ячеек под фильтр.
func (s *CatalogService) ListCells(ctx context.Context, q CellsQuery) (Page[model.Cell], error) {
	limit, offset := clampPaging(q.Limit, q.Offset)
	items, total, err := s.cells.List(ctx, repository.CellsFilter{
		Query: q.Query, WarehouseID: q.WarehouseID, IsFloor: q.IsFloor, Limit: limit, Offset: offset,
	})
	if err != nil {
		return Page[model.Cell]{}, err
	}
	return Page[model.Cell]{Items: items, Total: total, Limit: limit, Offset: offset}, nil
}

// StockQuery — входные параметры выборки остатков.
type StockQuery struct {
	GoodID *string
	CellID *string
	Limit  int
	Offset int
}

// ListStock — страница остатков (товарный разрез / содержимое ячейки).
func (s *CatalogService) ListStock(ctx context.Context, q StockQuery) (Page[model.StockItem], error) {
	limit, offset := clampPaging(q.Limit, q.Offset)
	items, total, err := s.stock.List(ctx, repository.StockFilter{
		GoodID: q.GoodID, CellID: q.CellID, Limit: limit, Offset: offset,
	})
	if err != nil {
		return Page[model.StockItem]{}, err
	}
	return Page[model.StockItem]{Items: items, Total: total, Limit: limit, Offset: offset}, nil
}
