package model

import (
	"time"

	"github.com/shopspring/decimal"
)

// StockKey — грань учёта остатка: количество однозначно определяется тройкой
// (ячейка, товар, партия). На неё опираются все движения (приход/расход/перенос).
type StockKey struct {
	CellID  string // uuid ячейки
	GoodID  string // uuid товара
	BatchID string // uuid партии
}

// Stock — остаток по грани StockKey с количеством. Qty — decimal (не float):
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
