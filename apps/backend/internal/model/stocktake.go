package model

import "errors"

// Виды области пересчёта (P10-01): что выбрал старший смены.
const (
	// StocktakeScopeCells — выбранные ячейки, каждая считается целиком.
	StocktakeScopeCells = "cells"
	// StocktakeScopeGroup — группы номенклатуры с поддеревом; матрица — тоже группа.
	StocktakeScopeGroup = "group"
	// StocktakeScopeSupplier — товары поставщиков.
	StocktakeScopeSupplier = "supplier"
	// StocktakeScopeGood — отдельные товары («по наименованию»).
	StocktakeScopeGood = "good"
	// StocktakeScopeInternalWarehouse — ячейки с остатком внутренних складов, целиком.
	StocktakeScopeInternalWarehouse = "internal_warehouse"
	// StocktakeScopeAll — весь склад: все ячейки, включая пустые.
	StocktakeScopeAll = "all"
)

// StocktakeScopeKinds — все виды области.
var StocktakeScopeKinds = []string{
	StocktakeScopeCells, StocktakeScopeGroup, StocktakeScopeSupplier, StocktakeScopeGood,
	StocktakeScopeInternalWarehouse, StocktakeScopeAll,
}

// StocktakeCountsAreaGoodsOnly — область считает в ячейке только свой товар: группа, поставщик,
// товар. Остальные виды считают ячейку целиком.
func StocktakeCountsAreaGoodsOnly(kind string) bool {
	return kind == StocktakeScopeGroup || kind == StocktakeScopeSupplier || kind == StocktakeScopeGood
}

// Статусы ячейки пересчёта (P10-01).
const (
	StocktakeCellPending   = "pending"
	StocktakeCellTaken     = "taken"
	StocktakeCellCounting  = "counting"
	StocktakeCellCounted   = "counted"
	StocktakeCellDisrupted = "disrupted"
)

// Ошибки пересчёта (P10-02). Живут в домене: их разбирает транспорт (dev.md §2).
var (
	// ErrInvalidStocktake — пересчёт задан неверно: неизвестный вид области, нет объектов там,
	// где они нужны, объекты у «всего склада», не-UUID.
	ErrInvalidStocktake = errors.New("invalid stocktake")
	// ErrStocktakeUnknownObject — объекта области нет в справочнике или ячейка чужого склада.
	ErrStocktakeUnknownObject = errors.New("stocktake scope object not found")
	// ErrStocktakeReceivingCell — в области ячейка приёмки: её товар ждёт размещения и в
	// пересчёте не участвует.
	ErrStocktakeReceivingCell = errors.New("receiving cell is not counted by stocktake")
	// ErrStocktakeNoCells — область не дала ни одной ячейки: считать нечего.
	ErrStocktakeNoCells = errors.New("stocktake scope has no cells")
	// ErrStocktakeCellNotFound — нет ячейки пересчёта с таким идентификатором.
	ErrStocktakeCellNotFound = errors.New("stocktake cell not found")
	// ErrStocktakeCellNotYours — ячейку пересчёта держит другой работник или она не в том
	// состоянии, чтобы начать подсчёт.
	ErrStocktakeCellNotYours = errors.New("stocktake cell is not taken by this user")
	// ErrStocktakeClosed — пересчёт уже закрыт.
	ErrStocktakeClosed = errors.New("stocktake is closed")
)

// StocktakeCreateInput — новый пересчёт: склад, вид области и её объекты, кто заводит.
//
// ObjectIDs — идентификаторы объектов вида ScopeKind (ячейки, группы, поставщики, товары или
// внутренние склады); у «всего склада» пусто.
type StocktakeCreateInput struct {
	WarehouseID string
	ScopeKind   string
	ObjectIDs   []string
	CreatedBy   string
}

// StocktakeCreated — заведённый пересчёт: документ, его задание и сколько ячеек дала область.
type StocktakeCreated struct {
	ID     string
	Number int64
	TaskID string
	Cells  int
}

// StocktakeCellSnapshot — что снято в начале подсчёта ячейки: строк «ожидалось» и марок.
type StocktakeCellSnapshot struct {
	Lines int
	Marks int
}
