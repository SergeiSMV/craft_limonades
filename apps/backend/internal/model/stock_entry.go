package model

import "time"

// StockEntryReportRow — строка отчёта «ввод остатков» (по закрытой сессии): ячейка, товар, партия, кол-во.
type StockEntryReportRow struct {
	CellAddress    string
	GoodCode       *string // «Код» 1С (может отсутствовать)
	GoodName       string
	ProductionDate string // ISO YYYY-MM-DD (из БД)
	Qty            string // decimal как текст (точное значение)
}

// StockEntryReport — данные отчёта по сессии: шапка (склад, время) + строки.
type StockEntryReport struct {
	WarehouseCode string
	WarehouseName string
	CreatedAt     time.Time
	Rows          []StockEntryReportRow
}

// StockEntryDocument — закрытая сессия ввода остатков как «документ» для портала «Инвентаризация».
type StockEntryDocument struct {
	ID            string
	WarehouseCode string
	WarehouseName string
	ClosedAt      time.Time
	LinesCount    int
}
