package model

import (
	"errors"
	"time"

	"github.com/shopspring/decimal"
)

// Ошибки просмотра содержимого (P5-05). Живут в домене, а не в репозитории: их проверяет
// транспорт, и он не должен ради errors.Is знать о хранилище (dev.md §2, долг 21).
var (
	// ErrLoadUnitNotFound — нет грузовой единицы с таким идентификатором.
	//
	// Отдельная ошибка, а не нарушение внешнего ключа: кладовщик сканировал ярлык короба,
	// которого система не знает, и это разбирается человеком, а не показывается как сбой БД.
	ErrLoadUnitNotFound = errors.New("load unit not found")
	// ErrCellNotFound — нет ячейки с таким идентификатором.
	ErrCellNotFound = errors.New("cell not found")
)

// ContentLine — товар одной партии с количеством: строка содержимого короба или россыпи
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

// LoadUnitCard — короб так, как его показывают кладовщику: где лежит и что внутри (P5-05).
//
// Live — короб «живой»: размещён в ячейке и не пуст. Явного признака «выведен из обращения»
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
	// InternalWarehouseID — склад короба целиком (P6-07-1): «Основной», «Брак», «Изолятор» …
	InternalWarehouseID string
}

// LooseLine — россыпь: товар партии в ячейке вне коробов (P5-05).
//
// Россыпь не хранится отдельно — это остаток ячейки за вычетом содержимого лежащих в ней
// коробов (см. ContentsRepository).
type LooseLine struct {
	CellID              string
	InternalWarehouseID string
	ContentLine
}

// CellContents — что лежит в ячейке: живые короба и россыпь (P5-05).
type CellContents struct {
	CellID      string
	Address     string
	WarehouseID string
	LoadUnits   []LoadUnitCard
	Loose       []LooseLine
}

// ContentsSnapshot — снимок для кэша ТСД: все живые короба с содержимым и вся россыпь (P5-05).
//
// AsOf — момент, на который снимок согласован (начало читающей транзакции); ТСД показывает
// его кладовщику как «данные на ЧЧ:ММ».
type ContentsSnapshot struct {
	AsOf      time.Time
	LoadUnits []LoadUnitCard
	Loose     []LooseLine
}

// LoadUnitReceipt — приёмка, которая завела короб (P5-05-1): кто, когда, от кого.
type LoadUnitReceipt struct {
	ReceiptID    string
	Doc          SupplierDoc // накладная поставщика (ADHOC-23)
	ReceivedBy   string      // ФИО кладовщика
	SupplierName *string     // nil — приёмка без поставщика
	PostedAt     *time.Time  // nil — документ ещё не оприходован
}

// LoadUnitMove — перенос короба из журнала размещений (P5-05-1), в том виде, в каком его читает
// человек: адреса ячеек и ФИО, а не идентификаторы.
type LoadUnitMove struct {
	FromAddress *string // nil — первое размещение: короб появился на складе
	ToAddress   string
	Source      string  // PlacementReceipt | PlacementPutaway | PlacementMove
	UserName    *string // nil — исполнитель неизвестен
	At          time.Time
}

// LoadUnitHistory — история короба: создание, переносы и изменения состава по порядку
// (P5-05-1, ADHOC-32).
type LoadUnitHistory struct {
	LoadUnitID string
	CreatedAt  time.Time
	Receipt    *LoadUnitReceipt // nil — короб не попал ни в одну приёмку
	Moves      []LoadUnitMove
	Contents   []LoadUnitContentEvent
}

// Изменения состава короба (ADHOC-32) — только физические: товар лёг в короб или ушёл из него.
// Пометка браком и решения офиса сами по себе в историю не идут — только то, что они сделали
// с товаром.
const (
	BoxContentIn       = "in"        // доложили перемещением
	BoxContentOut      = "out"       // вынули перемещением
	BoxContentProblem  = "problem"   // вынули в россыпь ячейки при пометке части короба
	BoxContentWriteOff = "write_off" // списали по решению офиса
	BoxContentReturn   = "return"    // отгрузили поставщику
)

// LoadUnitContentEvent — изменение состава короба: какой товар, сколько, откуда или куда,
// кто и когда (ADHOC-32).
type LoadUnitContentEvent struct {
	Kind           string
	GoodName       string
	Uom            string
	ProductionDate time.Time
	Qty            decimal.Decimal
	// Место на той стороне: ячейка, откуда доложили или куда вынули; у пометки — ячейка короба;
	// у списания и отгрузки — пусто. PeerLoadUnitID — короб на той стороне, если товар
	// переложили из короба в короб.
	PeerAddress    *string
	PeerLoadUnitID *string
	UserName       *string
	At             time.Time
}
