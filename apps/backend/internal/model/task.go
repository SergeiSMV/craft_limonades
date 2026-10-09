package model

import (
	"time"

	"github.com/shopspring/decimal"
)

// Виды заданий для склада (P5-02-1). Набор растёт вместе с операциями: P10 — пересчёт.
const (
	// TaskPutaway — разместить товар, лёгший приёмкой в ячейку приёмки.
	TaskPutaway = "putaway"
)

// Статусы задания: пул new → in_progress (взято) → done.
const (
	TaskNew        = "new"
	TaskInProgress = "in_progress"
	TaskDone       = "done"
)

// Task — задание для склада, как его видит исполнитель (P5-02-1).
//
// Status — статус ДЛЯ ТОГО, КТО СМОТРИТ: зависшее чужое задание показывается «новым»,
// потому что взять его уже можно. Хранимый статус при этом не меняется — время само по себе
// в базе ничего не трогает.
type Task struct {
	ID          string
	Number      int64
	Kind        string
	Status      string
	WarehouseID string

	// Основание — приёмка: поставщик (пусто — без поставщика) и момент оприходования.
	ReceiptID    *string
	SupplierName string
	ReceivedAt   *time.Time
	// Накладная поставщика приёмки-основания (ADHOC-23); nil — задание не от приёмки.
	DocNumber *string
	DocDate   *time.Time

	AssigneeID   *string
	AssigneeName string
	TakenAt      *time.Time
	CreatedAt    time.Time

	Items []PutawayTaskItem
}

// PutawayTaskItem — позиция задания на размещение: короб целиком ЛИБО россыпь.
//
// Остаток считается по проведённым сеансам этого задания, а не хранится: короб размещён,
// если его переносил сеанс задания; россыпи осталось столько, сколько не перенесли.
type PutawayTaskItem struct {
	LineNo int

	// Короб: идентификатор и состав (что внутри — чтобы кладовщик видел, что несёт).
	LoadUnitID *string
	Contents   []TaskGoodQty
	Placed     bool

	// Россыпь: товар, партия, количество по заданию и сколько ещё разместить.
	Good           *TaskGood
	BatchID        *string
	ProductionDate *time.Time
	Qty            decimal.Decimal
	Remaining      decimal.Decimal
}

// TaskGood — товар позиции в том виде, в каком его показывает ТСД.
type TaskGood struct {
	ID   string
	Code string
	Name string
	Uom  string
}

// TaskGoodQty — товар с партией и количеством (состав короба).
type TaskGoodQty struct {
	Good           TaskGood
	ProductionDate time.Time
	Qty            decimal.Decimal
}

// CompletedTask — запись ленты «Завершённые»: задание целиком (P5-02-1).
type CompletedTask struct {
	ID           string
	Number       int64
	Kind         string
	SupplierName string
	DocNumber    *string    // накладная приёмки-основания (ADHOC-23); nil — нет
	DocDate      *time.Time // её дата
	CompletedAt  time.Time
	// Исполнители — все, кто проводил по заданию сеансы, в порядке первого захода.
	Executors []TaskUser
	Sessions  int
}

// TaskUser — исполнитель задания.
type TaskUser struct {
	ID       string
	FullName string
}

// CompletedTasksFilter — фильтр ленты «Завершённые».
//
// From/To — границы по времени завершения (To не включается); ExecutorID — кто участвовал
// в задании; Kind — вид. Пустые поля фильтр не сужают. Before* — курсор подгрузки: отдаются
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
)

// TaskEvent — запись журнала задания: что случилось, кто, когда.
//
// UserName пуст у системных событий (задание заведено приёмкой). PrevUserName — у кого
// перехвачено зависшее задание. PutawayID — заход, если событие о нём.
type TaskEvent struct {
	Event        string
	UserName     string
	PrevUserName string
	PutawayID    *string
	At           time.Time
}

// TaskSession — один заход по заданию: проведённый сеанс размещения.
type TaskSession struct {
	PutawayID string
	User      TaskUser
	PostedAt  time.Time
	Lines     []TaskSessionLine
}

// TaskSessionLine — строка захода: короб или россыпь, откуда → куда.
type TaskSessionLine struct {
	LoadUnitID     *string
	Good           *TaskGood
	ProductionDate *time.Time
	Qty            *decimal.Decimal
	FromAddress    string
	ToAddress      string
}
