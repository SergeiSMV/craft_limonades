package model

import (
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
