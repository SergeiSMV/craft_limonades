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
