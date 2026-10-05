package model

import "time"

// Виды документов и источников (P3-01). Значения попадают в БД как есть, поэтому меняться
// не могут: строка kind — часть формата хранения, а не деталь реализации.
const (
	// ReportKindStockEntry — форма «ввод остатков» (P-FS-08). Дальше добавится «Движение» (P5/P6).
	ReportKindStockEntry = "stock_entry"
	// ReportKindReceipt — форма «Поступление» (P4-10).
	ReportKindReceipt = "receipt"

	// SourceTypeStockEntrySession — операция-источник: сессия ввода остатков.
	SourceTypeStockEntrySession = "stock_entry_session"
	// SourceTypeReceipt — операция-источник: документ приёмки.
	SourceTypeReceipt = "receipt"
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

	// Шапка «Поступления» (P4-10). У ввода остатков полей нет, и omitempty держит прежние
	// снимки байт в байт такими, какими они были сохранены.
	//
	// Supplier пуст — приёмка без поставщика (внутреннее поступление, возврат).
	Supplier string `json:"supplier,omitempty"`
	// Executor — кто принимал: ФИО автора документа приёмки.
	Executor string `json:"executor,omitempty"`
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

// Статусы документа (P3-02). Значения лежат в БД под CHECK-ограничением, менять их нельзя
// без миграции.
const (
	// DocStatusNew — документ опубликован и ждёт оператора.
	DocStatusNew = "new"
	// DocStatusDownloaded — файл скачали; в 1С ещё не отмечен.
	DocStatusDownloaded = "downloaded"
	// DocStatusDone — оператор занёс документ в 1С и отметил «Выполнено».
	DocStatusDone = "done"
)

// DocumentListItem — строка списка документов в портале. Снимок целиком сюда не тянем:
// список показывает шапку и статус, а содержимое нужно только при скачивании.
type DocumentListItem struct {
	ID            string
	Kind          string
	WarehouseCode string
	WarehouseName string
	Supplier      string // только у «Поступления»; пусто — без поставщика или другая форма
	CreatedAt     time.Time
	LinesCount    int
	Status        string
	DownloadedAt  *time.Time
	DoneAt        *time.Time
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

// События журнала документа (P3-03). Значения лежат в БД под CHECK — менять только миграцией.
const (
	// DocEventCreated — документ сформирован в транзакции завершения операции.
	DocEventCreated = "created"
	// DocEventDownloaded — файл скачали. Пишется на КАЖДОЕ скачивание, а не только на первое.
	DocEventDownloaded = "downloaded"
	// DocEventDone — оператор отметил документ занесённым в 1С.
	DocEventDone = "done"
	// DocEventGenerationFailed — файл не собрался; в details лежит причина.
	DocEventGenerationFailed = "generation_failed"
)

// DocumentEvent — запись журнала: что случилось с документом, когда и по чьей воле.
// UserName пустое, когда событие системное или автор не сохранился (события до P3-03).
type DocumentEvent struct {
	Event     string
	UserID    *string
	UserName  string
	Details   string
	CreatedAt time.Time
}
