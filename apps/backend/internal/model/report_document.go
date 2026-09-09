package model

import "time"

// Виды документов и источников (P3-01). Значения попадают в БД как есть, поэтому меняться
// не могут: строка kind — часть формата хранения, а не деталь реализации.
const (
	// ReportKindStockEntry — форма «ввод остатков» (P-FS-08). Дальше добавятся «Поступление» (P4)
	// и «Движение» (P5/P6).
	ReportKindStockEntry = "stock_entry"

	// SourceTypeStockEntrySession — операция-источник: сессия ввода остатков.
	SourceTypeStockEntrySession = "stock_entry_session"
)

// ReportSnapshot — содержимое документа, замороженное на момент завершения операции.
//
// Зачем отдельный тип с json-тегами, а не переиспользование StockEntryReport: снимок лежит
// в БД и переживает любой рефакторинг внутренних структур. Если хранить внутреннюю модель,
// переименование её поля молча испортит чтение всех ранее сохранённых документов — теги
// делают формат хранения явным контрактом.
type ReportSnapshot struct {
	WarehouseCode string              `json:"warehouse_code"`
	WarehouseName string              `json:"warehouse_name"`
	CreatedAt     time.Time           `json:"created_at"`
	Rows          []ReportSnapshotRow `json:"rows"`
}

// ReportSnapshotRow — строка документа. Числа и даты хранятся текстом: qty — decimal, который
// нельзя гонять через float без потери точности, production_date — уже отформатированная дата.
type ReportSnapshotRow struct {
	CellAddress    string  `json:"cell_address"`
	GoodCode       *string `json:"good_code"`
	GoodName       string  `json:"good_name"`
	ProductionDate string  `json:"production_date"`
	Qty            string  `json:"qty"`
}

// ReportDocument — документ отчёта: чем он порождён и что в нём заморожено.
type ReportDocument struct {
	ID         string
	Kind       string
	SourceType string
	SourceID   string
	Snapshot   ReportSnapshot
	CreatedAt  time.Time
}
