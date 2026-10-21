package model

import "time"

// Проблемы склада (P6-07-1): пометка короба или товара другим внутренним складом — брак,
// изолятор и т. п. (ADR-0016). Брак — лишь метка и программная изоляция: товар остаётся
// в той же ячейке и перемещается как любой другой.

// Причины проблемы — фиксированный список (решение 2026-10-14). Значения лежат в БД под CHECK —
// менять только миграцией. Склад назначения причина не диктует: его выбирает кладовщик.
const (
	ProblemReasonBreakage    = "breakage"     // бой
	ProblemReasonSpoilage    = "spoilage"     // порча
	ProblemReasonExpired     = "expired"      // просрок
	ProblemReasonForeignMark = "foreign_mark" // не наша марка ЧЗ
	ProblemReasonOther       = "other"        // прочее — с обязательным комментарием
)

// ProblemReasons — все причины, в порядке показа.
var ProblemReasons = []string{
	ProblemReasonBreakage, ProblemReasonSpoilage, ProblemReasonExpired,
	ProblemReasonForeignMark, ProblemReasonOther,
}

// InternalWarehouse — внутренний склад: «Основной», «Брак», «Изолятор» … (ADR-0016).
//
// IsActive — виден в выборе (скрытый остаётся у остатка и в подписях); InUse — на складе
// есть остаток или история, удалить его нельзя, только скрыть (ADHOC-29). Системный склад
// (SystemRole, P6-07-3) не скрывается и не удаляется: на него переводит программа.
type InternalWarehouse struct {
	ID        string
	Code      string
	Name      string
	IsDefault bool
	IsActive  bool
	InUse     bool
	// SystemRole — роль системного склада (P6-07-3); пусто — обычный склад.
	SystemRole string
}

// Решения офиса по проблеме (P6-07-3). Значения лежат в БД под CHECK — менять только миграцией.
const (
	ProblemDecisionWriteOff       = "write_off"       // списать по документу 1С
	ProblemDecisionPlace          = "place"           // разместить: вернуть в «Основной»
	ProblemDecisionSupplierReturn = "supplier_return" // возврат поставщику через задание
)

// Статусы проблемы.
const (
	ProblemStatusOpen     = "open"
	ProblemStatusResolved = "resolved"
)

// problemDecisions — какие решения допустимы при какой причине (решение 2026-10-21), в порядке
// показа. Причину определяет склад, решение — офис; лишнее решение отклоняется сервером.
var problemDecisions = map[string][]string{
	ProblemReasonBreakage:    {ProblemDecisionWriteOff},
	ProblemReasonSpoilage:    {ProblemDecisionWriteOff, ProblemDecisionSupplierReturn},
	ProblemReasonExpired:     {ProblemDecisionWriteOff, ProblemDecisionSupplierReturn},
	ProblemReasonForeignMark: {ProblemDecisionPlace, ProblemDecisionSupplierReturn},
	ProblemReasonOther:       {ProblemDecisionWriteOff, ProblemDecisionPlace, ProblemDecisionSupplierReturn},
}

// ProblemDecisionsFor — решения, допустимые при причине; неизвестная причина — пусто.
// Возвращается копия: список — справочник, а не рабочий срез вызывающего.
func ProblemDecisionsFor(reason string) []string {
	return append([]string(nil), problemDecisions[reason]...)
}

// InternalWarehouseRoleSupplierReturn — роль системного склада «Возврат поставщику» (P6-07-3):
// туда переводит решение «возврат», выбрать его при пометке проблемы нельзя.
const InternalWarehouseRoleSupplierReturn = "supplier_return"

// ResolveProblemInput — решение офиса по проблеме, проводимое кнопкой «Провести» (P6-07-3).
//
// DocNumber и DocDate — документ списания 1С, только у списания; SupplierID — кому возвращаем,
// только у возврата.
type ResolveProblemInput struct {
	ProblemID  string
	Decision   string
	DocNumber  string
	DocDate    string // ISO 'YYYY-MM-DD'
	SupplierID string
	ResolvedBy string
}

// ProblemFilter — отбор рабочего списка «Проблемы склада»: статус (пусто — все).
type ProblemFilter struct {
	Status string
}

// ProblemItem — товар проблемы: у открытой — что помечено сейчас (состав короба или товар
// проблемы), у решённой — что решение фактически взяло, с ячейкой.
type ProblemItem struct {
	GoodID         string
	GoodCode       string
	GoodName       string
	ProductionDate string // ISO
	Qty            string
	CellAddress    string
}

// Problem — проблема склада в рабочем списке офиса (P6-07-3).
type Problem struct {
	ID            string
	CreatedAt     time.Time
	CreatedByName string
	CellAddress   string
	LoadUnitID    string // короб целиком; пусто — товар
	Reason        string
	Comment       string
	Mark          string
	FromWarehouse string // имя внутреннего склада, откуда помечено
	ToWarehouse   string // имя склада-метки
	Items         []ProblemItem

	// Поставщик товара по справочнику — подсказка оператору для возврата; пусто, если у товаров
	// проблемы поставщики разные или не указаны.
	SuggestedSupplierID string

	Status         string
	Decision       string
	DocNumber      string
	DocDate        string // ISO
	SupplierID     string
	SupplierName   string
	ReturnTaskNo   int64
	ResolvedByName string
	ResolvedAt     *time.Time
}
