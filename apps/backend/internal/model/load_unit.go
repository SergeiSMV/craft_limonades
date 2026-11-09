package model

import "time"

// Виды грузовой единицы (P4-01). Значения лежат в БД под CHECK — менять только миграцией.
const (
	// LoadUnitBox — короб: то, что собирают на приёмке.
	LoadUnitBox = "box"
	// LoadUnitPallet — паллета. Паллетная логика вне объёма пилота, вид заведён заранее.
	LoadUnitPallet = "pallet"
)

// Статусы грузовой единицы (P4-01).
const (
	// LoadUnitOpen — собирается: в неё ещё кладут товар на приёмке.
	LoadUnitOpen = "open"
	// LoadUnitClosed — собрана и закрыта, ждёт размещения.
	LoadUnitClosed = "closed"
	// LoadUnitPlaced — размещена в ячейке.
	LoadUnitPlaced = "placed"
)

// LoadUnit — грузовая единица: короб или паллета, которую двигают целиком.
//
// ID выдаёт устройство (UUID, P4-04) и он же кодируется в QR ярлыка — отдельного qr_id нет
// намеренно: два источника истины расходятся.
type LoadUnit struct {
	ID        string
	Kind      string
	ParentID  *string
	CellID    *string
	Status    string
	CreatedAt time.Time
}

// Источники размещения ГЕ — какая операция перенесла короб в ячейку (P5-01).
const (
	// PlacementReceipt — приёмка положила короб на место (по умолчанию в дефолтную ячейку).
	PlacementReceipt = "receipt"
	// PlacementPutaway — размещение перенесло короб в ячейку хранения (P5-02).
	PlacementPutaway = "putaway"
	// PlacementMove — перемещение перенесло короб из ячейки в ячейку (P6).
	PlacementMove = "move"
	// PlacementStockEntry — ввод остатков завёл короб в ячейке прохода (ADHOC-46).
	PlacementStockEntry = "stock_entry"
	// PlacementStocktake — пересчёт нашёл учётный короб в другой ячейке и перенёс его туда
	// (P10-03).
	PlacementStocktake = "stocktake"
	// PlacementPicking — «Завершить сборку» поставила короб отгрузки в ячейку `ОТГРУЗКА` (P9-07).
	PlacementPicking = "picking"
)

// Placement — одна строка журнала размещений: ГЕ перенесли из ячейки в ячейку (P5-01).
//
// Текущее место ГЕ — LoadUnit.CellID; журнал отвечает, где она лежала раньше и кто её двигал.
// Адреса ячеек приходят вместе со строкой: журнал читают люди (просмотр ГЕ по скану, P5-05),
// и идентификаторы ячеек им ничего не говорят.
type Placement struct {
	ID          string
	LoadUnitID  string
	FromCellID  *string // nil — первое размещение: ГЕ появилась на складе
	FromAddress *string
	ToCellID    string
	ToAddress   string
	Source      string
	ReceiptID   *string
	PutawayID   *string
	MovementID  *string
	UserID      *string
	PlacedAt    time.Time
}

// PlaceLoadUnitInput — что нужно, чтобы перенести ГЕ в ячейку (P5-01).
type PlaceLoadUnitInput struct {
	LoadUnitID string
	CellID     string
	Source     string  // PlacementReceipt | PlacementPutaway | PlacementMove | PlacementStockEntry
	UserID     string  // кто переносит; пусто — неизвестен
	ReceiptID  *string // документ приёмки, если переносит она
	PutawayID  *string // документ размещения, если переносит он (P5-02)
	MovementID *string // документ движения, если переносит перемещение (P6-01)
	// StockEntryID — сессия ввода остатков, если короб завёл проход (ADHOC-46).
	StockEntryID *string
	// StocktakeCellID — ячейка пересчёта, в которой нашли короб (P10-03).
	StocktakeCellID *string
}
