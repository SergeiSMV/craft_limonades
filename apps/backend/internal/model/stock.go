package model

import (
	"time"

	"github.com/shopspring/decimal"
)

// StockKey - грань учёта остатка: количество однозначно определяется тройкой
// (ячейка, товар, партия). На неё опираются все движения (приход/расход/перенос).
type StockKey struct {
	CellID  string // uuid ячейки
	GoodID  string // uuid товара
	BatchID string // uuid партии
	// InternalWarehouseID - учётная принадлежность остатка (ADR-0016): «основной», «брак» и т.д.
	// Одна физическая ячейка держит остатки разных внутренних складов одновременно, поэтому
	// без этого поля они схлопывались бы в одну строку и затирали друг друга.
	InternalWarehouseID string
}

// Stock - остаток по грани StockKey с количеством. Qty - decimal (не float):
// количества дробные (uom='кг') и должны быть точными, без ошибок округления.
type Stock struct {
	ID        string
	CellID    string
	GoodID    string
	BatchID   string
	Qty       decimal.Decimal
	CreatedAt time.Time
	UpdatedAt time.Time
}
