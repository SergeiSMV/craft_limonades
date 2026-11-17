package model

import "time"

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
