package model

import (
	"errors"
	"strings"
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

// Отказы в сборке заказа (P9-03, P9-04): ошибки состояния заказа, а не сбои. Текст - по-русски:
// ТСД показывает его кладовщику дословно.
var (
	ErrPickingOrderNotFound = errors.New("заказ сборки не найден")
	ErrPickingOrderDeleted  = errors.New("заказ удалён в 1С")
	ErrPickingOrderUnknown  = errors.New("в заказе есть нераспознанные позиции: обновите номенклатуру и загрузите реестр повторно")
	ErrPickingOrderClosed   = errors.New("заказ уже собран или отгружен")
	ErrPickingOrderTaken    = errors.New("заказ уже взял другой сотрудник")
	// ErrPickingOrderNotYours - действие по заказу, который не в работе у этого кладовщика:
	// его сняли, он завис и его перехватили, или он ещё не взят.
	ErrPickingOrderNotYours = errors.New("заказ не у вас в работе: возьмите его заново")
	ErrPickingLineNotFound  = errors.New("строки нет в заказе или она убрана реестром")
	// ErrPickingBoxForeign - ярлык с этим кодом уже принадлежит другому коробу.
	ErrPickingBoxForeign = errors.New("этот ярлык уже занят другим коробом")
	// ErrPickingBoxID - id короба от ТСД не UUID: ярлык не в формате ГЕ.
	ErrPickingBoxID = errors.New("ярлык короба не распознан")
	// ErrPickingBoxNotEmpty - удалить можно только пустой короб: в нём есть пики.
	ErrPickingBoxNotEmpty = errors.New("в коробе есть товар: сначала верните его в источник")

	// Пик (P9-05).
	ErrPickingOverPlan      = errors.New("больше, чем осталось собрать по строке")
	ErrPickingSourceDenied  = errors.New("из этой ячейки или склада собирать нельзя")
	ErrPickingBoxNotInOrder = errors.New("короб отгрузки не из этого заказа")
	ErrPickingSourceIsBox   = errors.New("короб отгрузки не источник сборки")
	ErrPickingPickExists    = errors.New("пик с этим идентификатором уже есть")
	ErrPickingPickNotFound  = errors.New("пик не найден")
	ErrPickingPickMoved     = errors.New("сборка заказа уже завершена: товар в коробе отгрузки")
	ErrPickingStockShort    = errors.New("в источнике не хватает товара: часть уже в сборке или перемещена")
	ErrPickingLoadUnitBusy  = errors.New("из короба идёт сборка: сначала завершите или верните пики")
	ErrPickingMarkInPicking = errors.New("марка уже взята в сборку")
)

// Что загрузка реестра делает с заказом (P8-02): так предпросмотр подписывает заказ и так
// загрузка решает, что писать.
const (
	PickingOrderNew       = "new"       // заказа этой даты ещё не было
	PickingOrderUnchanged = "unchanged" // строки те же - пропускается молча
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

// PickingExistingLine - строка плана уже загруженного заказа, и убранная (Removed) тоже: по
// тройке «код + партия» строка ищется и тогда, когда она возвращается в реестр.
type PickingExistingLine struct {
	ID        string
	GoodCode  string
	GoodName  string
	BatchDate *time.Time
	PlanQty   int
	Removed   bool
}

// PickingExistingOrder - заказ, уже загруженный на ту же дату, со строками.
type PickingExistingOrder struct {
	ID          string
	Number      int64
	OrderNumber string
	Status      string
	Deleted     bool
	PickedBy    *string // кто завершил сборку: ему возвращается заказ на дособор
	Lines       []PickingExistingLine
}

// PickingOrderHeader - шапка заказа из реестра.
type PickingOrderHeader struct {
	InvoiceNumber string
	OrderNumber   string
	OrderDate     *time.Time
	Direction     string
	Client        string
	Address       string
	HasUnknown    bool
}

// PickingPlanLine - строка плана после свёртки тройки «код + партия» файла. ExistingID - строка
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

// PickingChange - правка заказа для истории; у правок всего заказа товара нет.
type PickingChange struct {
	Kind      string
	GoodCode  string
	GoodName  string
	BatchDate *time.Time
	OldQty    *int
	NewQty    *int
}

// PickingOrderPlan - что загрузка делает с одним заказом.
//
// Kind - из констант PickingOrder*. Header и Lines - из файла (у удалённого их нет).
// Frozen - заказ отгружен: строки не трогаются, пишутся только правки и пометка «изменён в 1С
// после отгрузки». Reopen - собранному заказу добавили товар: он снова «в работе» у того, кто
// его собрал (дособор только на разницу).
type PickingOrderPlan struct {
	Kind           string
	ExistingID     string
	Status         string // статус до загрузки; у нового - new
	Header         *PickingOrderHeader
	Lines          []PickingPlanLine
	RemovedLineIDs []string
	Changes        []PickingChange
	Frozen         bool
	Reopen         bool
	PickedBy       *string
}

// PickingLoadInput - шапка загрузки реестра.
type PickingLoadInput struct {
	WarehouseID  string
	RegistryDate time.Time
	FileName     string
	UploadedBy   string
}

// PickingStock - остаток товара по партии, из которого можно собирать: склады с галочкой
// «разрешить сборку», ячейки хранения (не приёмка и не отгрузка).
type PickingStock struct {
	GoodID    string
	BatchDate time.Time
	Qty       float64
}

// PickingTaskOrder - заказ сборки с планом для подбора (P9-03): шапка, статус и строки, в том
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
	// Picks - открытые пики заказа («в сборке», P9-06): ТСД по ним показывает собранное и
	// возвращает пик, сделанный с другого терминала или до переустановки приложения.
	Picks []PickingOpenPick
}

// PickingTaskLine - строка плана заказа и сколько по ней уже взято.
//
// GoodID - nil у кода вне справочника. CellID и CellAddress - ячейка реестра, найденная в WMS;
// RegistryCell - адрес как в файле. Taken - открытые и перенесённые в короб пики строки
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

// PickingOpenPick - открытый пик заказа (P9-06): что, откуда и в какой короб взято.
//
// LoadUnitID - короб хранения-источник, пусто у россыпи; CellAddress - ячейка источника
// (у короба - его ячейка в момент пика). Marks - КИ маркируемого товара.
type PickingOpenPick struct {
	ID          string
	LineID      string
	BoxID       string
	CellAddress string
	LoadUnitID  string
	BatchDate   time.Time
	Qty         decimal.Decimal
	Marks       []string
}

// PickingBox - короб отгрузки заказа: «короб Seq» на ярлыке.
type PickingBox struct {
	LoadUnitID string
	Seq        int
}

// PickingOrderListItem - заказ в списке «СБОРКА» на ТСД (P9-04).
//
// Mine - заказ в работе у этого кладовщика. Busy - в работе у другого и не завис: взять нельзя;
// зависший (8 ч без движения) считается свободным. AssigneeName - у занятого и своего.
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
	IsPartial     bool // у собранного: «собран частично»
	Boxes         int  // живых коробов отгрузки
}

// PickingShortageResult - итог отметки «не хватает» (P9-04). StocktakeNumber - пересчёт позиции:
// заведённый этой отметкой (Created) или уже открытый по товару; nil - считать негде (товара нет
// ни в одной ячейке, и ячейки реестра нет в WMS).
type PickingShortageResult struct {
	StocktakeNumber *int64
	Created         bool
}

// События заказа сборки (P9-07, picking_order_events.kind): журнал для отчётов - кто брал,
// отказывался, был снят, собрал и отгрузил.
const (
	PickingEventTaken          = "taken"
	PickingEventTakenOver      = "taken_over"
	PickingEventReleased       = "released"
	PickingEventReleasedByLead = "released_by_lead"
	PickingEventCompleted      = "completed"
	PickingEventReopened       = "reopened"
	PickingEventShipped        = "shipped"
	// PickingEventReturned - вернул на место по заданию «вернуть на места» (P9-07-1).
	PickingEventReturned = "returned"
)

// Отказы завершения сборки, ярлыков и отгрузки (P9-07).
var (
	// ErrPickingNothingTaken - «Завершить сборку» по заказу, в котором ничего не взято: отгружать
	// нечего, коробов нет.
	ErrPickingNothingTaken = errors.New("в заказе ничего не взято: завершать нечего")
	ErrPickingNotPicked    = errors.New("заказ ещё не собран")
	// ErrPickingShipBoxes - отсканированы не все короба заказа или чужой короб.
	ErrPickingShipBoxes = errors.New("отсканированы не все короба заказа")
	// ErrPickingReprintDenied - ярлык этого короба уже печатали, а права на повторную печать нет.
	ErrPickingReprintDenied = errors.New("ярлык уже напечатан: повторную печать делает старший смены")
)

// Отказы возврата на места (P9-07-1).
var (
	// ErrPickingReturnPending - «Отгрузить» заказ, у которого есть что вернуть на места: лишнее
	// уехало бы клиенту и списалось со склада.
	ErrPickingReturnPending = errors.New("сначала верните лишнее на места: задание «Вернуть на места»")
	// ErrPickingReturnOverLeft - вернуть больше, чем осталось вернуть по строке или есть в пике.
	ErrPickingReturnOverLeft = errors.New("больше, чем осталось вернуть по позиции")
	// ErrPickingReturnCell - вернуть можно только в ячейку хранения склада заказа.
	ErrPickingReturnCell = errors.New("вернуть можно только в ячейку хранения этого склада")
	// ErrPickingReturnMarks - марки не из этого пика или их число не равно количеству.
	ErrPickingReturnMarks = errors.New("марки не из этого короба отгрузки или их число не равно количеству")
	// ErrPickingReturnNotMoved - пик ещё «в сборке»: его возвращают пиком назад (picking_unpick).
	ErrPickingReturnNotMoved = errors.New("товар ещё не перенесён в короб отгрузки: верните его в источник")
	// ErrPickingReturnExists - возврат с этим идентификатором уже есть (другая операция).
	ErrPickingReturnExists = errors.New("возврат с этим идентификатором уже есть")
)

// PickingReturnView - что вернуть на места по заказу (P9-07-1): шапка и позиции-пики.
//
// Left у строки - сколько вернуть по ней: перенесённое сверх плана; у удалённого заказа - всё
// взятое, и «в сборке» тоже. Позиции - пики, из которых можно вернуть: перенесённые (из короба
// отгрузки в любую ячейку хранения) и, у удалённого заказа, открытые (назад в источник).
type PickingReturnView struct {
	OrderID       string
	Number        int64
	InvoiceNumber string
	OrderNumber   string
	Client        string
	Status        string
	Deleted       bool
	TaskID        *string
	Lines         []PickingReturnLine
	Picks         []PickingReturnPick
}

// PickingReturnLine - строка заказа, по которой есть что вернуть.
type PickingReturnLine struct {
	LineID   string
	GoodName string
	Left     decimal.Decimal
}

// PickingReturnPick - пик, из которого возвращают. Moved - в коробе отгрузки (BoxSeq - его
// номер «N из M»), иначе ещё «в сборке» у источника.
type PickingReturnPick struct {
	PickID           string
	LineID           string
	Moved            bool
	BoxID            string
	BoxSeq           int
	GoodID           string
	GoodCode         string
	GoodName         string
	Uom              string
	Marked           bool
	ProductionDate   time.Time
	Qty              decimal.Decimal
	SourceCellID     string
	SourceCell       string
	SourceLoadUnitID *string
	Marks            []string
}

// PickingLinesError - «Завершить сборку» отказано по строкам (P9-07): Incomplete - взято меньше
// плана без отметки «не хватает», Excess - «в сборке» больше плана (лишнее вернуть пиком).
// Текст - по-русски со списком товаров: ТСД показывает его дословно.
type PickingLinesError struct {
	Incomplete []string
	Excess     []string
}

func (e *PickingLinesError) Error() string {
	msg := ""
	if len(e.Excess) > 0 {
		msg = "взято больше плана, верните лишнее: " + strings.Join(e.Excess, ", ")
	}
	if len(e.Incomplete) > 0 {
		if msg != "" {
			msg += ". "
		}
		msg += "не собрано - соберите или отметьте «не хватает»: " + strings.Join(e.Incomplete, ", ")
	}
	return msg
}

// PickingShipment - собранный заказ для ярлыков и отгрузки (P9-07): шапка реестра, короба
// «N из M» и итог. Boxes - живые короба по номеру, M = len(Boxes).
type PickingShipment struct {
	ID            string
	Number        int64
	RegistryDate  time.Time
	InvoiceNumber string
	OrderNumber   string
	Direction     string
	Client        string
	Address       string
	Status        string
	IsPartial     bool
	Deleted       bool
	Qty           decimal.Decimal
	// ReturnLeft - сколько вернуть на места после правки реестра (P9-07-1): пока не ноль,
	// отгрузка закрыта.
	ReturnLeft decimal.Decimal
	Boxes      []PickingShipmentBox
}

// PickingShipmentBox - короб отгрузки: номер, сколько в нём штук, сколько раз печатали ярлык,
// отгружен ли.
type PickingShipmentBox struct {
	LoadUnitID    string
	Seq           int
	Qty           decimal.Decimal
	LabelsPrinted int
	Shipped       bool
}

// ErrShippingCell - ячейка отгрузки в движении (P9-05): в ней числятся короба собранных заказов,
// и уходят они оттуда только отгрузкой.
var ErrShippingCell = errors.New("ячейка отгрузки - служебная: короба собранных заказов уходят из неё только отгрузкой")
