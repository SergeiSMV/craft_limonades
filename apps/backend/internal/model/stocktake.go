package model

import (
	"errors"
	"time"

	"github.com/shopspring/decimal"
)

// Виды области пересчёта (P10-01): что выбрал старший смены.
const (
	// StocktakeScopeCells - выбранные ячейки, каждая считается целиком.
	StocktakeScopeCells = "cells"
	// StocktakeScopeGroup - группы номенклатуры с поддеревом; матрица - тоже группа.
	StocktakeScopeGroup = "group"
	// StocktakeScopeSupplier - товары поставщиков.
	StocktakeScopeSupplier = "supplier"
	// StocktakeScopeGood - отдельные товары («по наименованию»).
	StocktakeScopeGood = "good"
	// StocktakeScopeInternalWarehouse - ячейки с остатком внутренних складов, целиком.
	StocktakeScopeInternalWarehouse = "internal_warehouse"
	// StocktakeScopeAll - весь склад: все ячейки, включая пустые.
	StocktakeScopeAll = "all"
)

// StocktakeScopeKinds - все виды области.
var StocktakeScopeKinds = []string{
	StocktakeScopeCells, StocktakeScopeGroup, StocktakeScopeSupplier, StocktakeScopeGood,
	StocktakeScopeInternalWarehouse, StocktakeScopeAll,
}

// StocktakeCountsAreaGoodsOnly - область считает в ячейке только свой товар: группа, поставщик,
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
	// ErrInvalidStocktake - пересчёт задан неверно: неизвестный вид области, нет объектов там,
	// где они нужны, объекты у «всего склада», не-UUID.
	ErrInvalidStocktake = errors.New("invalid stocktake")
	// ErrStocktakeUnknownObject - объекта области нет в справочнике или ячейка чужого склада.
	ErrStocktakeUnknownObject = errors.New("stocktake scope object not found")
	// ErrStocktakeReceivingCell - в области служебная ячейка: в приёмке товар ждёт размещения, в
	// отгрузке - короба собранных заказов (P9-02); в пересчёте они не участвуют.
	ErrStocktakeReceivingCell = errors.New("receiving cell is not counted by stocktake")
	// ErrStocktakeNoCells - область не дала ни одной ячейки: считать нечего.
	ErrStocktakeNoCells = errors.New("stocktake scope has no cells")
	// ErrStocktakeCellNotFound - нет ячейки пересчёта с таким идентификатором.
	ErrStocktakeCellNotFound = errors.New("ячейка пересчёта не найдена")
	// ErrStocktakeCellNotYours - ячейку пересчёта держит другой работник или она не в том
	// состоянии, чтобы начать подсчёт.
	ErrStocktakeCellNotYours = errors.New("ячейка пересчёта не взята вами - возьмите её в списке")
	// ErrStocktakeClosed - пересчёт уже закрыт.
	ErrStocktakeClosed = errors.New("пересчёт уже закрыт")
)

// StocktakeCreateInput - новый пересчёт: склад, вид области и её объекты, кто заводит.
//
// ObjectIDs - идентификаторы объектов вида ScopeKind (ячейки, группы, поставщики, товары или
// внутренние склады); у «всего склада» пусто.
//
// PickingOrderID и ExtraCellIDs - у пересчёта позиции по нехватке при сборке (P9-04): основание -
// заказ сборки, к ячейкам области добавляется ячейка реестра, где товара по учёту нет.
type StocktakeCreateInput struct {
	WarehouseID    string
	ScopeKind      string
	ObjectIDs      []string
	CreatedBy      string
	PickingOrderID string
	ExtraCellIDs   []string
}

// StocktakeCreated - заведённый пересчёт: документ, его задание и сколько ячеек дала область.
type StocktakeCreated struct {
	ID     string
	Number int64
	TaskID string
	Cells  int
}

// Ошибки подсчёта ячейки и закрытия пересчёта (P10-03). Текст - по-русски: отказ операции
// очереди ТСД показывает кладовщику дословно (P10-04).
var (
	// ErrStocktakeNotFound - нет пересчёта с таким идентификатором.
	ErrStocktakeNotFound = errors.New("stocktake not found")
	// ErrStocktakeCellBusy - ячейку уже держит другой работник: взять её нельзя.
	ErrStocktakeCellBusy = errors.New("ячейку уже взял другой сотрудник")
	// ErrStocktakeCellCounted - ячейка уже подсчитана.
	ErrStocktakeCellCounted = errors.New("ячейка уже подсчитана")
	// ErrStocktakeCellDisrupted - пока ячейку считали, через неё прошло движение: подсчёт не
	// годится, ячейку нужно начать заново.
	ErrStocktakeCellDisrupted = errors.New("пока ячейку считали, через неё прошло движение - посчитайте ячейку заново")
	// ErrStocktakeCellNotCounting - подсчёт ячейки не начат: факт без снимка не с чем сравнить.
	ErrStocktakeCellNotCounting = errors.New("подсчёт ячейки не начат - отсканируйте ячейку на месте")
	// ErrStocktakeOutOfArea - в факте товар не из области пересчёта.
	ErrStocktakeOutOfArea = errors.New("товар не из области пересчёта")
	// ErrStocktakeUnknownBox - найден короб, которого нет в WMS: его заводят приёмкой или
	// «Вводом остатков», а не пересчётом.
	ErrStocktakeUnknownBox = errors.New("короба нет в WMS - заведите его приёмкой или «Вводом остатков»")
	// ErrStocktakeUnknownMark - найдена марка, которой нет на складе WMS.
	ErrStocktakeUnknownMark = errors.New("марки нет на складе WMS - заведите её приёмкой или «Вводом остатков»")
	// ErrStocktakeInProblem - найденный короб или марка в открытой проблеме склада («Не найдено»,
	// возврат): их судьбу решает офис, пересчёт их не трогает.
	ErrStocktakeInProblem = errors.New("товар в открытой проблеме склада - его судьбу решает офис")
	// ErrStocktakeMarksRequired - маркируемый товар россыпью считается марками.
	ErrStocktakeMarksRequired = errors.New("маркируемый товар считается сканом каждой марки")
	// ErrStocktakeUncounted - в пересчёте есть неподсчитанные ячейки, а закрыть досрочно не
	// подтвердили.
	ErrStocktakeUncounted = errors.New("stocktake has uncounted cells")
)

// Виды позиции снимка (P10-03): россыпь или короб целиком.
const (
	StocktakePositionLoose = "loose"
	StocktakePositionBox   = "box"
)

// StocktakePosition - позиция снимка ячейки, как её видит кладовщик: что искать, без количеств
// (слепой счёт, решение 2026-10-26).
type StocktakePosition struct {
	Kind                string
	InternalWarehouseID string

	// Короб целиком.
	LoadUnitID *string
	CZCode     *string

	// Россыпь: товар и партия; Marked - считается марками.
	GoodID         *string
	GoodCode       string
	GoodName       string
	Uom            string
	ProductionDate *time.Time
	Marked         bool
}

// StocktakeCell - ячейка пересчёта, как её видит работник.
//
// Status - для того, кто смотрит: взятая другим и зависшая (не начата дольше срока) - pending,
// её снова можно взять.
type StocktakeCell struct {
	ID          string
	StocktakeID string
	CellID      string
	Address     string
	Status      string
	TakenByName string
	TakenAt     *time.Time
	StartedAt   *time.Time
	CountedAt   *time.Time
	Mine        bool
}

// StocktakeLine - строка пересчёта для портала: что ожидалось по снимку и что посчитано.
// GoodName пусто - строка короба (LoadUnitID): ожидался ли короб (0/1) и найден ли. Fact nil -
// ячейку ещё не посчитали. Problem - недостача ушла проблемой «не найдено» (короб, марки).
type StocktakeLine struct {
	CellAddress    string
	CellStatus     string
	LoadUnitID     string
	GoodCode       string
	GoodName       string
	Uom            string
	ProductionDate *time.Time
	Expected       decimal.Decimal
	Fact           *decimal.Decimal
	Problem        bool
}

// CellUnderCount - ячейка склада сейчас на подсчёте пересчёта (ADHOC-48): что ТСД
// показывает кладовщику перед движением через неё - кто считает и какой пересчёт.
type CellUnderCount struct {
	StocktakeNumber int64
	Address         string
	CountedByName   string
	StartedAt       time.Time
}

// StocktakeCellView - ячейка на подсчёте с позициями снимка: что ТСД показывает кладовщику.
type StocktakeCellView struct {
	StocktakeCell
	Positions []StocktakePosition
}

// Stocktake - пересчёт с ходом выполнения: шапка и ячейки.
type Stocktake struct {
	ID            string
	Number        int64
	WarehouseID   string
	ScopeKind     string
	Status        string
	TaskID        string
	CreatedByName string
	CreatedAt     time.Time
	ClosedAt      *time.Time
	Cells         []StocktakeCell
}

// StocktakeLooseFact - факт россыпи по позиции: товар, партия датой, склад (пусто - «Основной»),
// количество; у маркируемого товара - найденные марки, количество - их число.
type StocktakeLooseFact struct {
	GoodID              string
	ProductionDate      string // ISO 'YYYY-MM-DD'
	InternalWarehouseID string
	Qty                 decimal.Decimal
	Marks               []string
}

// StocktakeCellSubmitInput - подсчёт ячейки из очереди ТСД: россыпь и найденные короба.
// Позиция снимка, которой нет в факте, - недостача.
type StocktakeCellSubmitInput struct {
	StocktakeCellID string
	UserID          string
	Loose           []StocktakeLooseFact
	Boxes           []string
}

// StocktakeCellResult - что сделал подсчёт ячейки: правок остатка, коробов перенесено сюда,
// проблем «не найдено».
type StocktakeCellResult struct {
	Adjustments int `json:"adjustments"`
	MovedBoxes  int `json:"moved_boxes"`
	Problems    int `json:"problems"`
}

// StocktakeListItem - пересчёт в списке портала (P10-05): шапка и ход без самих ячеек.
type StocktakeListItem struct {
	ID            string
	Number        int64
	ScopeKind     string
	Status        string
	CreatedByName string
	CreatedAt     time.Time
	ClosedAt      *time.Time
	Cells         int
	Counted       int
}
