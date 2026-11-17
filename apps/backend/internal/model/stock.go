package model

import (
	"errors"
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

// ErrInsufficientStock - попытка списать больше, чем есть в (ячейка, товар, партия).
var ErrInsufficientStock = errors.New("insufficient stock")

// ErrEmptyInternalWarehouse - в ключе остатка не задана учётная принадлежность.
//
// Отдельная ошибка, а не отказ БД: пустая строка доходит до запроса и падает невнятным
// «invalid input syntax for type uuid», по которому непонятно, что именно забыли. Поле добавилось
// к StockKey уже после того, как операции остатка разошлись по коду, и компилятор такие места
// не подсвечивает - литерал структуры с именованными полями собирается и без него.
var ErrEmptyInternalWarehouse = errors.New("internal warehouse is required in stock key")

// ErrNoDefaultInternalWarehouse - в справочнике нет склада по умолчанию. Заводить остаток
// «куда-нибудь» нельзя: учётная принадлежность - часть грани, и ошибка здесь тихо исказит учёт.
var ErrNoDefaultInternalWarehouse = errors.New("no default internal warehouse")

// Ошибки сервиса остатков.
var (
	// ErrInvalidQuantity - количество движения должно быть строго положительным.
	// Направление (приход/расход) задаёт операция, а не знак числа.
	ErrInvalidQuantity = errors.New("quantity must be positive")
)
