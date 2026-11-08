package model

import (
	"errors"
	"time"

	"github.com/shopspring/decimal"
)

// Статусы заказа сборки (P9-02): свои у WMS, статус из реестра 1С не берётся.
const (
	PickingStatusNew        = "new"
	PickingStatusInProgress = "in_progress"
	PickingStatusPicked     = "picked"
	PickingStatusShipped    = "shipped"
)

// Отказы в сборке заказа (P9-03, P9-04): ошибки состояния заказа, а не сбои. Текст — по-русски:
// ТСД показывает его кладовщику дословно.
var (
	ErrPickingOrderNotFound = errors.New("заказ сборки не найден")
	ErrPickingOrderDeleted  = errors.New("заказ удалён в 1С")
	ErrPickingOrderUnknown  = errors.New("в заказе есть нераспознанные позиции: обновите номенклатуру и загрузите реестр повторно")
	ErrPickingOrderClosed   = errors.New("заказ уже собран или отгружен")
	ErrPickingOrderTaken    = errors.New("заказ уже взял другой сотрудник")
	// ErrPickingOrderNotYours — действие по заказу, который не в работе у этого кладовщика:
	// его сняли, он завис и его перехватили, или он ещё не взят.
	ErrPickingOrderNotYours = errors.New("заказ не у вас в работе: возьмите его заново")
	ErrPickingLineNotFound  = errors.New("строки нет в заказе или она убрана реестром")
	// ErrPickingBoxForeign — ярлык с этим кодом уже принадлежит другому коробу.
	ErrPickingBoxForeign = errors.New("этот ярлык уже занят другим коробом")
	// ErrPickingBoxID — id короба от ТСД не UUID: ярлык не в формате ГЕ.
	ErrPickingBoxID = errors.New("ярлык короба не распознан")
)

// Что загрузка реестра делает с заказом (P8-02): так предпросмотр подписывает заказ и так
// загрузка решает, что писать.
const (
	PickingOrderNew       = "new"       // заказа этой даты ещё не было
	PickingOrderUnchanged = "unchanged" // строки те же — пропускается молча
	PickingOrderChanged   = "changed"   // добавлены, убраны строки или изменено количество
	PickingOrderDeleted   = "deleted"   // заказ пропал из реестра своей даты
	PickingOrderRestored  = "restored"  // пропавший раньше заказ вернулся
)

// Виды правок заказа в истории (picking_order_changes.kind).
const (
	PickingChangeLineAdded     = "line_added"
	PickingChangeLineRemoved   = "line_removed"
	PickingChangeQtyChanged    = "qty_changed"
	PickingChangeOrderDeleted  = "order_deleted"
	PickingChangeOrderRestored = "order_restored"
)

// PickingExistingLine — строка плана уже загруженного заказа, и убранная (Removed) тоже: по
// тройке «код + партия» строка ищется и тогда, когда она возвращается в реестр.
type PickingExistingLine struct {
	ID        string
	GoodCode  string
	GoodName  string
	BatchDate *time.Time
	PlanQty   int
	Removed   bool
}

// PickingExistingOrder — заказ, уже загруженный на ту же дату, со строками.
type PickingExistingOrder struct {
	ID          string
	Number      int64
	OrderNumber string
	Status      string
	Deleted     bool
	PickedBy    *string // кто завершил сборку: ему возвращается заказ на дособор
	Lines       []PickingExistingLine
}

// PickingOrderHeader — шапка заказа из реестра.
type PickingOrderHeader struct {
	InvoiceNumber string
	OrderNumber   string
	OrderDate     *time.Time
	Direction     string
	Client        string
	Address       string
	HasUnknown    bool
}

// PickingPlanLine — строка плана после свёртки тройки «код + партия» файла. ExistingID — строка
// уже есть у заказа (в том числе убранная): обновляется на месте, иначе заводится новая.
type PickingPlanLine struct {
	ExistingID   string
	GoodCode     string
	GoodName     string
	GoodID       *string
	BatchDate    *time.Time
	Qty          int
	RegistryCell string
	CellID       *string
}

// PickingChange — правка заказа для истории; у правок всего заказа товара нет.
type PickingChange struct {
	Kind      string
	GoodCode  string
	GoodName  string
	BatchDate *time.Time
	OldQty    *int
	NewQty    *int
}

// PickingOrderPlan — что загрузка делает с одним заказом.
//
// Kind — из констант PickingOrder*. Header и Lines — из файла (у удалённого их нет).
// Frozen — заказ отгружен: строки не трогаются, пишутся только правки и пометка «изменён в 1С
// после отгрузки». Reopen — собранному заказу добавили товар: он снова «в работе» у того, кто
// его собрал (дособор только на разницу).
type PickingOrderPlan struct {
	Kind           string
	ExistingID     string
	Status         string // статус до загрузки; у нового — new
	Header         *PickingOrderHeader
	Lines          []PickingPlanLine
	RemovedLineIDs []string
	Changes        []PickingChange
	Frozen         bool
	Reopen         bool
	PickedBy       *string
}

// PickingLoadInput — шапка загрузки реестра.
type PickingLoadInput struct {
	WarehouseID  string
	RegistryDate time.Time
	FileName     string
	UploadedBy   string
}

// PickingStock — остаток товара по партии, из которого можно собирать: склады с галочкой
// «разрешить сборку», ячейки хранения (не приёмка и не отгрузка).
type PickingStock struct {
	GoodID    string
	BatchDate time.Time
	Qty       float64
}

// PickingTaskOrder — заказ сборки с планом для подбора (P9-03): шапка, статус и строки, в том
// числе убранные реестром (по ним взятое возвращается на места, подбора у них нет).
type PickingTaskOrder struct {
	ID            string
	Number        int64
	WarehouseID   string
	RegistryDate  time.Time
	InvoiceNumber string
	OrderNumber   string
	Direction     string
	Client        string
	Address       string
	Status        string
	HasUnknown    bool
	Deleted       bool
	AssigneeID    *string
	Lines         []PickingTaskLine
	Boxes         []PickingBox
}

// PickingTaskLine — строка плана заказа и сколько по ней уже взято.
//
// GoodID — nil у кода вне справочника. CellID и CellAddress — ячейка реестра, найденная в WMS;
// RegistryCell — адрес как в файле. Taken — открытые и перенесённые в короб пики строки
// (возвращённые на место не считаются).
type PickingTaskLine struct {
	ID           string
	LineNo       int
	GoodID       *string
	GoodCode     string
	GoodName     string
	Uom          string
	CZMarked     bool
	BatchDate    *time.Time
	RegistryCell string
	CellID       *string
	CellAddress  string
	PlanQty      int
	Taken        decimal.Decimal
	Removed      bool
	Shortage     bool
}

// PickingBox — короб отгрузки заказа: «короб Seq» на ярлыке.
type PickingBox struct {
	LoadUnitID string
	Seq        int
}

// PickingOrderListItem — заказ в списке «СБОРКА» на ТСД (P9-04).
//
// Mine — заказ в работе у этого кладовщика. Busy — в работе у другого и не завис: взять нельзя;
// зависший (8 ч без движения) считается свободным. AssigneeName — у занятого и своего.
type PickingOrderListItem struct {
	ID            string
	Number        int64
	RegistryDate  time.Time
	InvoiceNumber string
	OrderNumber   string
	Direction     string
	Client        string
	Address       string
	Status        string
	HasUnknown    bool
	Lines         int
	Mine          bool
	Busy          bool
	AssigneeName  string
}

// PickingShortageResult — итог отметки «не хватает» (P9-04). StocktakeNumber — пересчёт позиции:
// заведённый этой отметкой (Created) или уже открытый по товару; nil — считать негде (товара нет
// ни в одной ячейке, и ячейки реестра нет в WMS).
type PickingShortageResult struct {
	StocktakeNumber *int64
	Created         bool
}
