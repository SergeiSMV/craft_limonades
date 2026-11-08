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
}
