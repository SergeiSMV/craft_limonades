package model

import (
	"time"

	"github.com/shopspring/decimal"
)

// PickingPortalOrder — заказ сборки в списке портала «Сборка-отгрузка» (P8-03): шапка реестра,
// статус WMS и пометки, кто держит или собрал заказ, итог плана и факта.
//
// План и факт — по живым строкам (убранные реестром не считаются). Факт — открытые пики и
// перенесённые в короб, возвращённые на место не считаются (как «взято» у ТСД). TakenAt — когда
// взят в работу; у нового — nil.
type PickingPortalOrder struct {
	ID                   string
	Number               int64
	RegistryDate         time.Time
	InvoiceNumber        string
	OrderNumber          string
	OrderDate            *time.Time
	Direction            string
	Client               string
	Address              string
	Status               string
	IsPartial            bool
	HasUnknown           bool
	Deleted              bool
	ChangedAfterShipment bool
	AssigneeName         string
	TakenAt              *time.Time
	PickedByName         string
	PickedAt             *time.Time
	ShippedAt            *time.Time
	Lines                int
	PlanQty              int
	FactQty              decimal.Decimal
	Boxes                int
	// ReturnLeft — сколько вернуть на места после правки реестра (P9-07-1).
	ReturnLeft decimal.Decimal
	// OutOfSync — отгруженный заказ расходится с 1С (P9-08): по строке план реестра не равен
	// отгруженному. Снимается сам, когда повторная загрузка реестра приводит план к факту.
	OutOfSync bool
}

// PickingPortalDetail — заказ в окне деталей портала и в выгрузке Excel (P8-03): обе стороны по
// каждой строке — что было в реестре и что сделано на складе, короба и правки реестра.
type PickingPortalDetail struct {
	Order   PickingPortalOrder
	Lines   []PickingPortalLine
	Boxes   []PickingPortalBox
	Changes []PickingPortalChange
	Events  []PickingPortalEvent
}

// PickingPortalEvent — событие журнала заказа (P9-07): вид (PickingEvent*), кто сделал и с кого
// снят или у кого перехвачен заказ; у завершения и отгрузки — коробов и штук.
type PickingPortalEvent struct {
	Kind     string
	UserName string
	PrevName string
	Boxes    *int
	Qty      *decimal.Decimal
	At       time.Time
}

// PickingPortalLine — строка плана и факт по ней.
//
// BatchDate — партия реестра (nil — FEFO); CellAddress — ячейка реестра, найденная в WMS,
// RegistryCell — как в файле. Facts — пики строки (кроме возвращённых): партия, откуда, в какой
// короб, сколько и марки ЧЗ.
type PickingPortalLine struct {
	ID           string
	LineNo       int
	GoodCode     string
	GoodName     string
	Known        bool // код найден в справочнике
	Uom          string
	CZMarked     bool
	BatchDate    *time.Time
	RegistryCell string
	CellAddress  string
	PlanQty      int
	Removed      bool
	Shortage     bool
	Facts        []PickingPortalFact
}

// FactQty — сколько взято по строке.
func (l PickingPortalLine) FactQty() decimal.Decimal {
	sum := decimal.Zero
	for _, f := range l.Facts {
		sum = sum.Add(f.Qty)
	}
	return sum
}

// PickingPickMoved — состояние пика «в коробе отгрузки» (picking_picks.state): после отгрузки
// пик остаётся в нём, поэтому перенесённое отгруженного заказа - это отгруженный факт.
const PickingPickMoved = "moved"

// PickingPortalFact — пик строки: State — picking («в сборке», товар ещё в ячейке) или moved
// (в коробе отгрузки). BoxSeq — «короб N» заказа.
type PickingPortalFact struct {
	BatchDate   time.Time
	CellAddress string
	BoxSeq      int
	Qty         decimal.Decimal
	State       string
	PickedBy    string
	PickedAt    time.Time
	Marks       []string
}

// PickingPortalBox — короб отгрузки заказа.
type PickingPortalBox struct {
	Seq       int
	ShippedAt *time.Time
}

// PickingPortalChange — правка заказа повторной загрузкой реестра: вид (PickingChange*), товар
// и количество до и после; OrderStatus — статус заказа в момент правки.
type PickingPortalChange struct {
	Kind        string
	GoodCode    string
	GoodName    string
	BatchDate   *time.Time
	OldQty      *int
	NewQty      *int
	OrderStatus string
	At          time.Time
	// Reason — откуда правка (PickingChangeReason*, P9-08); считает ClassifyPickingChanges.
	Reason string
}

// Причина правки реестра для человека (P9-08): по статусу заказа в момент правки и, после
// отгрузки, по отгруженному факту.
const (
	PickingChangeReasonOrder    = "order"    // заказ не начинали собирать - изменение заказа в 1С
	PickingChangeReasonPicking  = "picking"  // во время сборки: дособор или возврат на места
	PickingChangeReasonFit      = "fit"      // после отгрузки, 1С приведена к отгруженному
	PickingChangeReasonDiverged = "diverged" // после отгрузки, расходится с отгруженным
)

// ClassifyPickingChanges проставляет причину каждой правке заказа d.
//
// Что: до сборки - изменение заказа в 1С (менеджер), во время сборки - своя причина, после
// отгрузки - «приведено к факту», если новое количество строки равно отгруженному, иначе
// «расходится». Зачем: правка 10 → 6 после отгрузки 6 - это исправление накладной по нехватке,
// а не решение менеджера. Как: отгруженное после отгрузки не меняется, поэтому сравнение с
// нынешним фактом стабильно. Правки целого заказа: удалён в 1С - к факту, если ничего не
// уехало; вернулся - к факту, если что-то уехало.
func ClassifyPickingChanges(d *PickingPortalDetail) {
	moved := map[string]decimal.Decimal{}
	total := decimal.Zero
	for _, l := range d.Lines {
		for _, f := range l.Facts {
			if f.State != PickingPickMoved {
				continue
			}
			k := pickingLineKey(l.GoodCode, l.BatchDate)
			moved[k] = moved[k].Add(f.Qty)
			total = total.Add(f.Qty)
		}
	}
	for i := range d.Changes {
		c := &d.Changes[i]
		switch c.OrderStatus {
		case PickingStatusNew:
			c.Reason = PickingChangeReasonOrder
			continue
		case PickingStatusInProgress, PickingStatusPicked:
			c.Reason = PickingChangeReasonPicking
			continue
		}
		var fit bool
		switch c.Kind {
		case PickingChangeOrderDeleted:
			fit = total.IsZero()
		case PickingChangeOrderRestored:
			fit = total.IsPositive()
		default:
			newQty := 0
			if c.NewQty != nil {
				newQty = *c.NewQty
			}
			fit = moved[pickingLineKey(c.GoodCode, c.BatchDate)].Equal(decimal.NewFromInt(int64(newQty)))
		}
		if fit {
			c.Reason = PickingChangeReasonFit
		} else {
			c.Reason = PickingChangeReasonDiverged
		}
	}
}

// pickingLineKey — строка заказа по тройке «код + партия» (партии нет - любая).
func pickingLineKey(code string, batch *time.Time) string {
	if batch == nil {
		return code + "|"
	}
	return code + "|" + batch.Format(time.DateOnly)
}
