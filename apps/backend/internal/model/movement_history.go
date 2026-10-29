package model

import (
	"time"

	"github.com/shopspring/decimal"
)

// История перемещений на ТСД (ADHOC-28): лента «Завершённые» в разделе «Перемещение».
//
// Кладовщик видит перемещения всего склада — кто и куда дел короб или товар, — а не только
// свои: разбирается, куда делся короб, и находит свою или чужую ошибку без офиса.

// MovementHistoryFilter — фильтр ленты истории.
//
// From/To — границы по времени проведения (To не включается); ExecutorID — кто двигал. Пустые
// поля фильтр не сужают. Before* — курсор подгрузки: отдаются записи строго «старше»
// последней показанной.
type MovementHistoryFilter struct {
	From, To       *time.Time
	ExecutorID     string
	BeforePostedAt *time.Time
	BeforeID       string
	Limit          int
}

// MovementRecord — запись ленты: документ движения целиком.
//
// LoadUnits и Goods — сколько в документе строк «короб целиком» и строк товара: по ним
// кладовщик узнаёт запись в ленте, не открывая её.
type MovementRecord struct {
	ID        string
	Number    int64  // номер документа своего вида: «ПМ» | «ПП» (ADHOC-55)
	Kind      string // MovementMove | MovementReplenish
	PostedAt  time.Time
	Executor  TaskUser
	LoadUnits int
	Goods     int
}

// MovementRecordLine — строка документа движения для человека: ГЕ целиком ЛИБО товар.
//
// Короба здесь показываются, в отличие от «Движения» для 1С: кладовщик мыслит коробами, и
// перекладывание из короба в россыпь той же ячейки ему важно увидеть.
type MovementRecordLine struct {
	LoadUnitID *string // ГЕ целиком

	GoodID         *string // товар; у строки ГЕ — nil
	GoodCode       *string
	GoodName       *string
	Uom            *string
	ProductionDate *time.Time
	Qty            *decimal.Decimal

	FromCellID      string
	FromCellAddress string
	FromLoadUnitID  *string // короб-источник товара; nil — россыпь
	ToCellID        string
	ToCellAddress   string
	ToLoadUnitID    *string // короб-приёмник товара; nil — россыпь
}

// MovementRecordDetail — запись ленты со строками.
type MovementRecordDetail struct {
	MovementRecord
	Lines []MovementRecordLine
}
