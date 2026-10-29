package model

import "time"

// Виды документов и источников (P3-01). Значения попадают в БД как есть, поэтому меняться
// не могут: строка kind — часть формата хранения, а не деталь реализации.
const (
	// ReportKindStockEntry — форма «ввод остатков» (P-FS-08).
	ReportKindStockEntry = "stock_entry"
	// ReportKindReceipt — форма «Поступление» (P4-10).
	ReportKindReceipt = "receipt"
	// ReportKindMovement — форма «Движение» (P5-04): одна на размещение, перемещение и
	// пополнение (P6); какая операция её породила — поле снимка Operation.
	ReportKindMovement = "movement"
	// ReportKindStocktake — форма «Инвентаризация» (P10-05): одна на пересчёт, при закрытии.
	ReportKindStocktake = "stocktake"

	// SourceTypeStockEntrySession — операция-источник: сессия ввода остатков.
	SourceTypeStockEntrySession = "stock_entry_session"
	// SourceTypeReceipt — операция-источник: документ приёмки.
	SourceTypeReceipt = "receipt"
	// SourceTypePutaway — операция-источник: документ (сеанс) размещения.
	SourceTypePutaway = "putaway"
	// SourceTypeMovement — операция-источник: документ движения — перемещение или
	// пополнение (P6-07).
	SourceTypeMovement = "movement"
	// SourceTypeStocktake — операция-источник: пересчёт (P10-05).
	SourceTypeStocktake = "stocktake"
)

// Операции «Движения» (P5-04). Значение лежит в снимке документа — менять нельзя.
const (
	// MovementOperationPutaway — размещение из зоны приёмки по ячейкам хранения.
	MovementOperationPutaway = "putaway"
	// MovementOperationMove — перемещение (P6-07). Совпадает с видом документа движения
	// (`movements.kind`): операция «Движения» перемещения — это и есть его вид.
	MovementOperationMove = MovementMove
	// MovementOperationReplenish — пополнение (P6-07). Пополнение заморожено, ТСД его
	// не шлёт; значение — задел, сервер документ пополнения проводит и публикует.
	MovementOperationReplenish = MovementReplenish
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
	// Executor — кто выполнил операцию: ФИО автора приёмки, сеанса размещения или
	// документа движения.
	Executor string `json:"executor,omitempty"`
	// Накладная поставщика (ADHOC-23): номер и дата в виде YYYY-MM-DD. Пусто — снимок,
	// сохранённый до ADHOC-23: прежние документы читаются как были.
	//
	// У «Движения» размещения Supplier, DocNumber и DocDate описывают приёмку-основание:
	// по ней оператор узнаёт в 1С, какой товар разносили.
	DocNumber string `json:"doc_number,omitempty"`
	DocDate   string `json:"doc_date,omitempty"`

	// Шапка «Движения» (P5-04). Operation — какая операция породила документ
	// (MovementOperation*); TaskNumber — номер задания-основания, 0 — операция без задания.
	Operation  string `json:"operation,omitempty"`
	TaskNumber int64  `json:"task_number,omitempty"`
	// ProblemNumber — проблема склада, решение по которой завело задание размещения
	// (ADHOC-55); 0 — задание родилось из приёмки или его нет.
	ProblemNumber int64 `json:"problem_number,omitempty"`

	// Шапка «Инвентаризации» (P10-05): номер пересчёта и вид его области; Executor — кто закрыл.
	StocktakeNumber int64  `json:"stocktake_number,omitempty"`
	ScopeKind       string `json:"scope_kind,omitempty"`
}

// ReportSnapshotRow — строка документа. Числа и даты хранятся текстом: qty — decimal, который
// нельзя гонять через float без потери точности, production_date — уже отформатированная дата.
//
// CellAddress — ячейка, где товар оказался: у ввода остатков и поступления это единственная
// ячейка строки, у «Движения» — ячейка-адресат.
type ReportSnapshotRow struct {
	CellAddress string `json:"cell_address"`
	// FromCellAddress — ячейка-отправитель «Движения» (P5-04); у остальных форм пусто.
	FromCellAddress string  `json:"from_cell_address,omitempty"`
	GoodCode        *string `json:"good_code"`
	GoodName        string  `json:"good_name"`
	ProductionDate  string  `json:"production_date"`
	Qty             string  `json:"qty"`
	// Mark — КИ марки ЧЗ (ADHOC-55): маркируемый товар в документе — строка на марку с
	// количеством 1 (у «Инвентаризации» — ожидалось и факт по 0 или 1). Пусто — строка без марки.
	Mark string `json:"mark,omitempty"`

	// Строка «Инвентаризации» (P10-05): склад WMS позиции, ожидалось, факт, расхождение (факт
	// минус ожидалось) и пометка — «не найдено — проблема склада», «не считалась». Qty у неё пуст.
	InternalWarehouse string `json:"internal_warehouse,omitempty"`
	Expected          string `json:"expected,omitempty"`
	Fact              string `json:"fact,omitempty"`
	Diff              string `json:"diff,omitempty"`
	Note              string `json:"note,omitempty"`
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
	DocNumber     string // накладная поставщика, только у «Поступления» (ADHOC-23); пусто — нет
	DocDate       string // её дата YYYY-MM-DD
	Operation     string // операция «Движения» (P5-04); пусто — другая форма
	TaskNumber    int64  // задание-основание «Движения»; 0 — нет
	ProblemNumber int64  // проблема склада — основание задания (ADHOC-55); 0 — нет
	// StocktakeNumber — пересчёт «Инвентаризации» (P10-05); 0 — другая форма.
	StocktakeNumber int64
	Executor        string // кто выполнил операцию (ФИО из снимка); пусто — снимок без исполнителя
	CreatedAt       time.Time
	LinesCount      int
	Status          string
	DownloadedAt    *time.Time
	DoneAt          *time.Time
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
