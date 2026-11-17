package model

import (
	"errors"
	"time"
)

// StockEntryReportRow - строка отчёта «ввод остатков» (по закрытой сессии): ячейка, товар, партия, кол-во.
type StockEntryReportRow struct {
	CellAddress    string
	GoodCode       *string // «Код» 1С (может отсутствовать)
	GoodName       string
	ProductionDate string // ISO YYYY-MM-DD (из БД)
	Qty            string // decimal как текст (точное значение)
	Mark           string // КИ марки ЧЗ - строка на марку (ADHOC-55); пусто - без марки
}

// StockEntryReport - данные отчёта по сессии: шапка (склад, время) + строки.
type StockEntryReport struct {
	WarehouseCode string
	WarehouseName string
	CreatedAt     time.Time
	Number        int64 // номер документа «Ввод остатков» (ADHOC-55); 0 - нет
	SourceNumber  int64 // номер сессии ввода остатков (ADHOC-55); 0 - нет
	Rows          []StockEntryReportRow
}

// Ошибки сессии ввода остатков.
var (
	// ErrSessionNotFound - нет сессии с таким id.
	ErrSessionNotFound = errors.New("stock entry session not found")
	// ErrSessionClosed - сессия уже финализирована (checkpoint/finalize по ней запрещены).
	ErrSessionClosed = errors.New("stock entry session already closed")
	// ErrSessionNotClosed - отчёт запрошен по ещё не завершённой сессии.
	ErrSessionNotClosed = errors.New("stock entry session not closed")
)

// Отказы строк ввода остатков с коробами и марками (ADHOC-46).
var (
	// ErrLoadUnitExists - короб с этим QR уже заведён на складе: проход его не пересчитывает.
	ErrLoadUnitExists = errors.New("load unit already exists")
	// ErrEntryDuplicate - короб, упаковка или марка уже введены в другой ячейке этого прохода.
	ErrEntryDuplicate = errors.New("already entered in another cell of the session")
	// ErrEntryCellHasMarks - в ячейке лежат марки россыпью того же товара и партии: SET россыпи
	// разошёлся бы с числом марок.
	ErrEntryCellHasMarks = errors.New("cell already has loose marks of this good and batch")
	// ErrEntryEmptyBox - короб прохода без товара.
	ErrEntryEmptyBox = errors.New("stock entry box has no goods")
)

// Ошибки ввода сессии остатков.
var (
	// ErrInvalidDate - дата выпуска не в формате DD-MM-YYYY либо несуществующая.
	ErrInvalidDate = errors.New("invalid production date (expected DD-MM-YYYY)")
	// ErrEmptyWarehouse - не передан склад для старта сессии.
	ErrEmptyWarehouse = errors.New("warehouse_id is required")
	// ErrEmptyCell - не передана ячейка в checkpoint.
	ErrEmptyCell = errors.New("cell_id is required")
	// ErrInvalidSessionID - клиент прислал session_id, не являющийся UUID.
	ErrInvalidSessionID = errors.New("session_id must be a UUID")
)
