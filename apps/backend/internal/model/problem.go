package model

import (
	"fmt"
	"time"
)

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
	ProblemReasonRetired     = "retired"      // марка ЧЗ выбыла из оборота (CZ-05)
	ProblemReasonOther       = "other"        // прочее — с обязательным комментарием
	// ProblemReasonNotFound — короб или марка не найдены пересчётом (P10-03). Заводит только
	// программа при подсчёте ячейки, поэтому в ProblemReasons (выбор на ТСД) её нет.
	ProblemReasonNotFound = "not_found"
	// ProblemReasonRegrade — пересорт (ADHOC-53): ШК перепривязан к другому товару, и марки
	// ЧЗ этого GTIN со склада перешли на него. Заводит только перепривязка ШК.
	ProblemReasonRegrade = "regrade"
)

// ProblemReasons — все причины, в порядке показа.
var ProblemReasons = []string{
	ProblemReasonBreakage, ProblemReasonSpoilage, ProblemReasonExpired,
	ProblemReasonForeignMark, ProblemReasonRetired, ProblemReasonOther,
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
	// ProblemDecisionRegrade — провести пересорт документом пересортицы 1С (ADHOC-53): товар уже
	// переведён перепривязкой, решение только связывает её с документом 1С.
	ProblemDecisionRegrade = "regrade"
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
	// Выбывшую марку продать нельзя — разместить обратно в «Основной» не даём (CZ-05).
	ProblemReasonRetired: {ProblemDecisionWriteOff, ProblemDecisionSupplierReturn},
	ProblemReasonOther:   {ProblemDecisionWriteOff, ProblemDecisionPlace, ProblemDecisionSupplierReturn},
	// Не найдено (P10-03): списать по документу 1С или «нашлось» — вернуть в «Основной».
	ProblemReasonNotFound: {ProblemDecisionWriteOff, ProblemDecisionPlace},
	ProblemReasonRegrade:  {ProblemDecisionRegrade},
}

// ProblemDocNumber — номер проблемы склада для человека: префикс «ПБ» и шесть цифр,
// «ПБ-000009» (ADHOC-55). Тот же вид, что у `docNumber` на ТСД и в портале: в документе 1С
// оператор видит проблему под тем же номером, что и в карточке.
func ProblemDocNumber(n int64) string {
	return fmt.Sprintf("ПБ-%06d", n)
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

// ResolvedProblemsFilter — страница ленты решённых проблем на ТСД (ADHOC-34): окно по времени
// решения `[From, To)` (nil — без границы) и курсор — время решения и id последней записи.
type ResolvedProblemsFilter struct {
	From, To         *time.Time
	BeforeResolvedAt *time.Time
	BeforeID         string
	Limit            int
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
	ID string
	// Number — номер проблемы для людей (ADHOC-55): счётчик вида, показ — с префиксом «ПБ».
	Number        int64
	CreatedAt     time.Time
	CreatedByName string
	CellAddress   string
	LoadUnitID    string // короб целиком; пусто — товар
	Reason        string
	Comment       string
	Mark          string
	// Пересорт (ADHOC-53): товар, за которым марки числились до перепривязки, и перепривязанный
	// ШК; у остальных причин пусто.
	FromGoodName string
	Barcode      string
	// Marks — КИ марок ЧЗ, привязанных к проблеме (CZ-06), по алфавиту (ADHOC-52): офис видит
	// и копирует марку — «не наша марка» без самой марки не проверить.
	Marks         []string
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

	// Отгрузка возврата поставщику (ADHOC-31): кто и когда отгрузил на ТСД; пусто — возврат
	// ещё ждёт отгрузки или решение другое. Исполнение решения для ленты склада (ADHOC-34).
	ShippedByName string
	ShippedAt     *time.Time

	// Photos — идентификаторы фото проблемы в порядке съёмки (ADHOC-45); сами снимки отдаются
	// отдельным запросом, в список не кладутся.
	Photos []string
}

// RegradeInput — перепривязка ШК к другому товару с пересортом марок ЧЗ (ADHOC-53).
type RegradeInput struct {
	Barcode string
	GoodID  string // новый товар
	UserID  string
}

// RegradeResult — итог перепривязки: проблема «Пересорт» и сколько марок перешло; марок на
// складе не было — проблемы нет.
type RegradeResult struct {
	ProblemID string
	Marks     int
}
