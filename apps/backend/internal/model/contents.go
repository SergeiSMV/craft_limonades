package model

import (
	"errors"
	"time"

	"github.com/shopspring/decimal"
)

// Ошибки просмотра содержимого (P5-05). Живут в домене, а не в репозитории: их проверяет
// транспорт, и он не должен ради errors.Is знать о хранилище (dev.md §2, долг 21).
var (
	// ErrLoadUnitNotFound - нет грузовой единицы с таким идентификатором.
	//
	// Отдельная ошибка, а не нарушение внешнего ключа: кладовщик сканировал ярлык короба,
	// которого система не знает, и это разбирается человеком, а не показывается как сбой БД.
	ErrLoadUnitNotFound = errors.New("load unit not found")
	// ErrCellNotFound - нет ячейки с таким идентификатором.
	ErrCellNotFound = errors.New("cell not found")
)

// ContentLine - товар одной партии с количеством: строка содержимого короба или россыпи
// в ячейке (P5-05).
//
// Наименование и единица едут вместе со строкой: карточку читает человек, а справочник
// товаров на ТСД может отставать от сервера на товар, заведённый после его загрузки.
type ContentLine struct {
	GoodID         string
	GoodCode       string
	GoodName       string
	Uom            string
	BatchID        string
	ProductionDate time.Time
	Qty            decimal.Decimal
}

// LoadUnitCard - короб так, как его показывают кладовщику: где лежит и что внутри (P5-05).
//
// Live - короб «живой»: размещён в ячейке и не пуст. Явного признака «выведен из обращения»
// у ГЕ нет (статус фактически ходит только open → placed, содержимое не убывает), поэтому
// живость выводится из места и содержимого. Определение останется верным, когда появятся
// операции, опустошающие короб (P6, P9).
type LoadUnitCard struct {
	ID          string
	Kind        string
	Status      string
	CellID      *string
	CellAddress *string
	CreatedAt   time.Time
	Live        bool
	Contents    []ContentLine // только строки с количеством больше нуля
	// InternalWarehouseID - склад короба целиком (P6-07-1): «Основной», «Брак», «Изолятор» …
	InternalWarehouseID string
	// CZCode - код короба ЧЗ (`00`+SSCC), если ГЕ - транспортный короб ЧЗ (CZ-03); nil - свой
	// короб с QR. По нему ТСД находит короб сканом этикетки ЧЗ, в том числе без связи (CZ-06).
	CZCode *string
	// CZOpened - короб ЧЗ вскрыт: из него вынута хоть одна марка (CZ-06).
	CZOpened bool
}

// LooseLine - россыпь: товар партии в ячейке вне коробов (P5-05).
//
// Россыпь не хранится отдельно - это остаток ячейки за вычетом содержимого лежащих в ней
// коробов (см. ContentsRepository).
//
// InPicking - сколько из Qty «в сборке» (P9-05): пикнуто в короб отгрузки, но ещё числится в
// ячейке до «Завершить сборку». Доступно для движения и пересчёта - Qty минус InPicking.
type LooseLine struct {
	CellID              string
	InternalWarehouseID string
	ContentLine
	InPicking decimal.Decimal
}

// CellContents - что лежит в ячейке: живые короба и россыпь (P5-05).
type CellContents struct {
	CellID      string
	Address     string
	WarehouseID string
	LoadUnits   []LoadUnitCard
	Loose       []LooseLine
}

// ContentsSnapshot - снимок для кэша ТСД: все живые короба с содержимым и вся россыпь (P5-05).
//
// AsOf - момент, на который снимок согласован (начало читающей транзакции); ТСД показывает
// его кладовщику как «данные на ЧЧ:ММ».
type ContentsSnapshot struct {
	AsOf      time.Time
	LoadUnits []LoadUnitCard
	Loose     []LooseLine
	Marks     []ContentsMark // марки ЧЗ на складе (CZ-06)
}

// ContentsMark - марка ЧЗ на складе в снимке для ТСД (CZ-06): по ней терминал без связи
// узнаёт, что за единицу отсканировали и где она лежит.
//
// Место - как у марки в базе: LoadUnitID (в коробе; ячейка - у короба) или CellID
// с InternalWarehouseID (россыпью). AggregateCode - упаковка ЧЗ, в которой марка пришла:
// скан групповой упаковки на ТСД - набор марок с этим кодом.
type ContentsMark struct {
	CIS                 string
	GoodID              string
	BatchID             string
	ProductionDate      time.Time
	LoadUnitID          *string
	CellID              *string
	InternalWarehouseID *string
	AggregateCode       *string
}

// LoadUnitReceipt - приёмка, которая завела короб (P5-05-1): кто, когда, от кого.
type LoadUnitReceipt struct {
	ReceiptID    string
	Number       int64       // номер приёмки, «ПР» (ADHOC-55)
	Doc          SupplierDoc // накладная поставщика (ADHOC-23)
	ReceivedBy   string      // ФИО кладовщика
	SupplierName *string     // nil - приёмка без поставщика
	PostedAt     *time.Time  // nil - документ ещё не оприходован
}

// LoadUnitMove - перенос короба из журнала размещений (P5-05-1), в том виде, в каком его читает
// человек: адреса ячеек и ФИО, а не идентификаторы.
type LoadUnitMove struct {
	FromAddress *string // nil - первое размещение: короб появился на складе
	ToAddress   string
	Source      string  // PlacementReceipt | PlacementPutaway | PlacementMove
	UserName    *string // nil - исполнитель неизвестен
	At          time.Time
	// Operation и OperationNumber - операция, перенёсшая короб, и её номер (ADHOC-55):
	// receipt | putaway | move | replenish | stocktake; пусто и 0 - операция без номера
	// (ввод остатков ссылки на сессию в журнале не хранит).
	Operation       string
	OperationNumber int64
}

// LoadUnitHistory - история короба: создание, переносы и изменения состава по порядку
// (P5-05-1, ADHOC-32).
type LoadUnitHistory struct {
	LoadUnitID string
	CreatedAt  time.Time
	Receipt    *LoadUnitReceipt // nil - короб не попал ни в одну приёмку
	Moves      []LoadUnitMove
	Contents   []LoadUnitContentEvent
}

// Изменения состава короба (ADHOC-32) - только физические: товар лёг в короб или ушёл из него.
// Пометка браком и решения офиса сами по себе в историю не идут - только то, что они сделали
// с товаром.
const (
	BoxContentIn       = "in"        // доложили перемещением
	BoxContentOut      = "out"       // вынули перемещением
	BoxContentProblem  = "problem"   // вынули в россыпь ячейки при пометке части короба
	BoxContentWriteOff = "write_off" // списали по решению офиса
	BoxContentReturn   = "return"    // отгрузили поставщику
)

// LoadUnitContentEvent - изменение состава короба: какой товар, сколько, откуда или куда,
// кто и когда (ADHOC-32).
type LoadUnitContentEvent struct {
	Kind           string
	GoodName       string
	Uom            string
	ProductionDate time.Time
	Qty            decimal.Decimal
	// Место на той стороне: ячейка, откуда доложили или куда вынули; у пометки - ячейка короба;
	// у списания и отгрузки - пусто. PeerLoadUnitID - короб на той стороне, если товар
	// переложили из короба в короб.
	PeerAddress    *string
	PeerLoadUnitID *string
	UserName       *string
	At             time.Time
}

// Ошибки просмотра содержимого.
var (
	// ErrInvalidCellID - идентификатор ячейки не UUID.
	ErrInvalidCellID = errors.New("cell id must be a UUID")
	// ErrInvalidShortCode - короткий код не из 1…8 шестнадцатеричных знаков.
	ErrInvalidShortCode = errors.New("short code must be 1 to 8 hex digits")
	// ErrInvalidCZBoxCode - код короба ЧЗ не `00` + 18 цифр SSCC.
	ErrInvalidCZBoxCode = errors.New("chestny znak box code must be 00 and 18 digits")
)
