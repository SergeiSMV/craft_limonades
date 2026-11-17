package model

import (
	"errors"
	"time"

	"github.com/shopspring/decimal"
)

// Статусы документа приёмки (P4-02). Значения лежат в БД под CHECK - менять только миграцией.
const (
	// ReceiptDraft - набирается на ТСД, строки ещё меняются.
	ReceiptDraft = "draft"
	// ReceiptPosted - оприходован: остаток поднят, документ неизменен.
	ReceiptPosted = "posted"
)

// Receipt - шапка документа приёмки.
//
// SupplierID необязателен: бывает внутреннее поступление и возврат, а выдуманный
// «прочий поставщик» потом всплыл бы в отчёте как настоящий.
type Receipt struct {
	ID          string
	WarehouseID string
	SupplierID  *string
	Doc         SupplierDoc
	Status      string
	CreatedBy   string
	PostedAt    *time.Time
	CreatedAt   time.Time
}

// ReceiptLine - строка приёмки: что, какой партии, сколько, куда и в какой ГЕ.
// LoadUnitID пуст, если товар принимают россыпью - грузовая единица добровольна.
type ReceiptLine struct {
	ID          string
	GoodID      string
	BatchID     string
	CellID      string
	LoadUnitID  *string
	Qty         decimal.Decimal
	Marks       []string // КИ марок ЧЗ строки (ADHOC-55); пусто - без марок
	GoodName    string   // для чтения документа; при записи не используется
	CellAddress string
}

// ReceiptLineInput - строка, как её присылает клиент: партия задаётся ДАТОЙ ВЫПУСКА,
// а не идентификатором. Кладовщик видит дату на упаковке и не знает про batch_id;
// сопоставление даты с партией - работа домена, а не устройства.
type ReceiptLineInput struct {
	GoodID         string
	ProductionDate string // ISO 'YYYY-MM-DD' (сервис уже привёл из транспортного DD-MM-YYYY)
	CellID         string
	LoadUnitID     string // пусто - россыпь
	Qty            decimal.Decimal
	// Marks - марки ЧЗ строки (CZ-05): единицы, принятые сканом марки или в составе короба ЧЗ.
	// Число марок не больше количества строки; пусто - строка без марок, как раньше.
	Marks []ReceiptMark
}

// SupplierDoc - документ поставщика, по которому пришёл товар (ADHOC-23): номер и дата
// накладной. Обязателен: накладной без номера кладовщик ставит «б/н».
type SupplierDoc struct {
	Number string
	Date   time.Time
}

// Ошибки документа приёмки (P4-02).
var (
	// ErrReceiptNotFound - нет документа с таким id.
	ErrReceiptNotFound = errors.New("receipt not found")
	// ErrReceiptPosted - документ уже оприходован: строки не меняются, повтор запрещён.
	ErrReceiptPosted = errors.New("receipt already posted")
	// ErrEmptyReceipt - оприходовать нечего: в документе нет строк.
	ErrEmptyReceipt = errors.New("receipt has no lines")
	// ErrLoadUnitCellConflict - строки одной ГЕ указывают разные ячейки.
	ErrLoadUnitCellConflict = errors.New("load unit lines point to different cells")
)

// ErrInvalidReceiptID - идентификатор документа приёмки не UUID.
//
// Отдельно от ErrEmptyReceiptID: у прямой ручки пустой id - это пропущенное поле, а в операции
// очереди документ адресуется своим id офлайн, и id не по форме означает испорченную операцию.
var ErrInvalidReceiptID = errors.New("receipt id must be a UUID")

// ErrEmptyReceiptID - не указан документ приёмки.
//
// Остальные проверки переиспользуют ошибки, уже заведённые соседними сервисами
// (ErrEmptyWarehouse, ErrEmptyGoodID, ErrInvalidQuantity, ErrInvalidDate): заводить синонимы
// значило бы, что хендлеру придётся сопоставлять две ошибки на один смысл. ErrEmptyCell приёмке
// не нужна - пустая ячейка здесь не ошибка, а просьба подставить умолчание (P4-03).
var ErrEmptyReceiptID = errors.New("receipt id is required")
