package model

import (
	"errors"
	"time"

	"github.com/shopspring/decimal"
)

// Виды заданий для склада (P5-02-1). Набор растёт вместе с операциями: P10 - пересчёт.
const (
	// TaskPutaway - разместить товар, лёгший приёмкой в ячейку приёмки.
	TaskPutaway = "putaway"
	// TaskSupplierReturn - отгрузить возврат поставщику (P6-07-3, ADHOC-31): позиции - проблемы,
	// решённые офисом возвратом этому поставщику.
	TaskSupplierReturn = "supplier_return"
	// TaskStocktake - пересчёт (P10-01): задание одно общее на пересчёт, его не берут целиком -
	// работники берут из него ячейки.
	TaskStocktake = "stocktake"
	// TaskPickingReturn - вернуть на места товар заказа сборки, который реестр изменил или удалил
	// после сборки (P9-07-1): одно открытое задание на заказ, остаток считается по пикам.
	TaskPickingReturn = "picking_return"
)

// Статусы задания: пул new → in_progress (взято) → done.
const (
	TaskNew        = "new"
	TaskInProgress = "in_progress"
	TaskDone       = "done"
)

// Task - задание для склада, как его видит исполнитель (P5-02-1).
//
// Status - статус ДЛЯ ТОГО, КТО СМОТРИТ: зависшее чужое задание показывается «новым»,
// потому что взять его уже можно. Хранимый статус при этом не меняется - время само по себе
// в базе ничего не трогает.
type Task struct {
	ID          string
	Number      int64
	Kind        string
	Status      string
	WarehouseID string

	// Основание - приёмка: поставщик (пусто - без поставщика) и момент оприходования.
	ReceiptID    *string
	SupplierName string
	ReceivedAt   *time.Time
	// Накладная поставщика приёмки-основания (ADHOC-23); nil - задание не от приёмки.
	DocNumber *string
	DocDate   *time.Time

	AssigneeID   *string
	AssigneeName string
	TakenAt      *time.Time
	CreatedAt    time.Time

	// StocktakeID - пересчёт задания вида stocktake (P10-03): ячейки берут из него.
	StocktakeID *string
	// Problem - проблема-основание задания на размещение по решению «разместить» (ADHOC-55);
	// nil - основание другое.
	Problem *TaskProblemInfo
	// Stocktake - номер, область и ход пересчёта (P10-04); nil - у других видов.
	Stocktake *TaskStocktakeInfo
	// Picking - заказ-основание возврата на места (P9-07-1); nil - у других видов.
	Picking *TaskPickingInfo

	Items []PutawayTaskItem
}

// TaskPickingInfo - заказ сборки, по которому вернуть товар на места (P9-07-1). Основание -
// «заказ удалён в 1С» (Deleted) или «изменение в реестре от ChangedAt»; Left - сколько штук
// осталось вернуть.
type TaskPickingInfo struct {
	OrderID       string
	Number        int64
	InvoiceNumber string
	OrderNumber   string
	Client        string
	Deleted       bool
	ChangedAt     *time.Time
	Left          decimal.Decimal
}

// TaskProblemInfo - проблема склада, по решению которой заведено задание на размещение
// (ADHOC-55): основание называют её номером.
type TaskProblemInfo struct {
	ID     string
	Number int64
}

// PutawayTaskItem - позиция задания: короб целиком ЛИБО россыпь. Та же форма у позиции
// возврата поставщику (ADHOC-31) - с проблемой-основанием и текущей ячейкой.
//
// Остаток считается по проведённым сеансам этого задания, а не хранится: короб размещён,
// если его переносил сеанс задания; россыпи осталось столько, сколько не перенесли.
type PutawayTaskItem struct {
	LineNo int

	// Короб: идентификатор и состав (что внутри - чтобы кладовщик видел, что несёт).
	LoadUnitID *string
	Contents   []TaskGoodQty
	Placed     bool
	// CZCode - код короба ЧЗ (`00`+SSCC), если короб задания - транспортный короб ЧЗ (CZ-06):
	// ярлыка у него нет, ТСД узнаёт его по скану этикетки ЧЗ.
	CZCode *string

	// Россыпь: товар, партия, количество по заданию и сколько ещё разместить.
	Good           *TaskGood
	BatchID        *string
	ProductionDate *time.Time
	Qty            decimal.Decimal
	Remaining      decimal.Decimal

	// Позиция возврата поставщику (ADHOC-31): проблема, решённая возвратом, и ячейка, где
	// позиция лежит сейчас. Placed у возврата - «отгружено». nil/пусто - позиция размещения.
	ProblemID   *string
	CellAddress string
	// Marks - КИ марок ЧЗ позиции возврата россыпью (CZ-06, долг 30): позиция отгружается,
	// только когда отсканированы все её марки. Пусто - позиция без марок или короб.
	Marks []string
}

// TaskGood - товар позиции в том виде, в каком его показывает ТСД.
type TaskGood struct {
	ID   string
	Code string
	Name string
	Uom  string
}

// TaskGoodQty - товар с партией и количеством (состав короба).
type TaskGoodQty struct {
	Good           TaskGood
	ProductionDate time.Time
	Qty            decimal.Decimal
}

// CompletedTask - запись ленты «Завершённые»: задание целиком (P5-02-1).
type CompletedTask struct {
	ID           string
	Number       int64
	Kind         string
	SupplierName string
	DocNumber    *string    // накладная приёмки-основания (ADHOC-23); nil - нет
	DocDate      *time.Time // её дата
	CompletedAt  time.Time
	// Исполнители - все, кто проводил по заданию сеансы, в порядке первого захода.
	Executors []TaskUser
	Sessions  int
	// Problem - проблема-основание размещения (ADHOC-55); nil - основание другое.
	Problem *TaskProblemInfo
	// Stocktake - пересчёт задания вида stocktake (ADHOC-58): номер, область, ход; nil - у других.
	// У пересчёта «заход» - подсчитанная ячейка, исполнители - кто считал.
	Stocktake *TaskStocktakeInfo
	// Picking - заказ сборки задания «вернуть на места» (P9-07-1); nil - у других видов.
	Picking *TaskPickingInfo
}

// TaskUser - исполнитель задания.
type TaskUser struct {
	ID       string
	FullName string
}

// CompletedTasksFilter - фильтр ленты «Завершённые».
//
// From/To - границы по времени завершения (To не включается); ExecutorID - кто участвовал
// в задании; Kind - вид. Пустые поля фильтр не сужают. Before* - курсор подгрузки: отдаются
// записи строго «старше» последней показанной.
type CompletedTasksFilter struct {
	From, To          *time.Time
	ExecutorID        string
	Kind              string
	BeforeCompletedAt *time.Time
	BeforeID          string
	Limit             int
}

// События журнала задания (P5-02-1).
const (
	TaskEventCreated     = "created"
	TaskEventTaken       = "taken"
	TaskEventReleased    = "released"
	TaskEventIntercepted = "intercepted"
	TaskEventSession     = "session"
	TaskEventCompleted   = "completed"
	// TaskEventCellCounted - ячейка пересчёта подсчитана (ADHOC-58). В task_events не пишется:
	// журнал задания дочитывает его из stocktake_cells, где факт подсчёта и так хранится.
	TaskEventCellCounted = "cell_counted"
)

// TaskEvent - запись журнала задания: что случилось, кто, когда.
//
// UserName пуст у системных событий (задание заведено приёмкой). PrevUserName - у кого
// перехвачено зависшее задание. PutawayID - заход, если событие о нём. Cell - адрес
// подсчитанной ячейки у события cell_counted (ADHOC-58), у прочих пуст.
type TaskEvent struct {
	Event        string
	UserName     string
	PrevUserName string
	PutawayID    *string
	Cell         string
	At           time.Time
}

// TaskSession - один заход по заданию: проведённый сеанс размещения.
type TaskSession struct {
	PutawayID string
	User      TaskUser
	PostedAt  time.Time
	Lines     []TaskSessionLine
}

// TaskSessionLine - строка захода: короб или россыпь, откуда → куда.
type TaskSessionLine struct {
	LoadUnitID     *string
	Good           *TaskGood
	ProductionDate *time.Time
	Qty            *decimal.Decimal
	FromAddress    string
	ToAddress      string
}

// TaskStocktakeInfo - пересчёт задания так, как его показывает плитка на ТСД (P10-04): номер,
// вид области и ход - сколько ячеек всего и сколько подсчитано.
type TaskStocktakeInfo struct {
	Number    int64
	ScopeKind string
	// CreatedBy - кто завёл пересчёт: у задания пересчёта автор - человек, а не система.
	CreatedBy string
	Cells     int
	Counted   int
}

// Ошибки заданий для склада (P5-02-1).
var (
	// ErrTaskNotFound - задания нет.
	ErrTaskNotFound = errors.New("task not found")
	// ErrTaskTaken - задание держит другой исполнитель, и оно не зависло.
	ErrTaskTaken = errors.New("task is taken by another user")
	// ErrTaskDone - задание уже выполнено.
	ErrTaskDone = errors.New("task is already done")
	// ErrTaskMismatch - сеанс не подходит заданию: другой вид или другой склад.
	ErrTaskMismatch = errors.New("putaway does not match the task")
	// ErrNotInTask - строка сеанса размещает то, чего нет в задании (или уже размещено им).
	ErrNotInTask = errors.New("putaway line is not part of the task")
	// ErrExceedsTask - россыпи размещают больше, чем осталось по заданию.
	ErrExceedsTask = errors.New("putaway line exceeds the task remainder")
)

// Ошибки входа заданий.
var (
	// ErrInvalidTaskFilter - фильтр ленты не разобран (дата, курсор, исполнитель).
	ErrInvalidTaskFilter = errors.New("invalid completed tasks filter")
)
