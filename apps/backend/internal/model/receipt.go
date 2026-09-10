package model

import (
	"time"

	"github.com/shopspring/decimal"
)

// Статусы документа приёмки (P4-02). Значения лежат в БД под CHECK — менять только миграцией.
const (
	// ReceiptDraft — набирается на ТСД, строки ещё меняются.
	ReceiptDraft = "draft"
	// ReceiptPosted — оприходован: остаток поднят, документ неизменен.
	ReceiptPosted = "posted"
)

// Receipt — шапка документа приёмки.
//
// SupplierID необязателен: бывает внутреннее поступление и возврат, а выдуманный
// «прочий поставщик» потом всплыл бы в отчёте как настоящий.
type Receipt struct {
	ID          string
	WarehouseID string
	SupplierID  *string
	Status      string
	CreatedBy   string
	PostedAt    *time.Time
	CreatedAt   time.Time
}

// ReceiptLine — строка приёмки: что, какой партии, сколько, куда и в какой ГЕ.
// LoadUnitID пуст, если товар принимают россыпью — грузовая единица добровольна.
type ReceiptLine struct {
	ID          string
	GoodID      string
	BatchID     string
	CellID      string
	LoadUnitID  *string
	Qty         decimal.Decimal
	GoodName    string // для чтения документа; при записи не используется
	CellAddress string
}

// ReceiptLineInput — строка, как её присылает клиент: партия задаётся ДАТОЙ ВЫПУСКА,
// а не идентификатором. Кладовщик видит дату на упаковке и не знает про batch_id;
// сопоставление даты с партией — работа домена, а не устройства.
type ReceiptLineInput struct {
	GoodID         string
	ProductionDate string // ISO 'YYYY-MM-DD' (сервис уже привёл из транспортного DD-MM-YYYY)
	CellID         string
	LoadUnitID     string // пусто — россыпь
	Qty            decimal.Decimal
}
