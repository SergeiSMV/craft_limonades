package model

import (
	"errors"
	"time"
)

// Проблемы склада (P6-07-1): пометка короба или товара другим внутренним складом — брак,
// изолятор и т. п. (ADR-0016). Брак — лишь метка и программная изоляция: товар остаётся
// в той же ячейке и перемещается как любой другой.

// Коды причин, на которые опирается программа (ADHOC-55: прочие причины — справочник
// `problem_reasons`, его ведёт офис). Склад назначения причина не диктует: его выбирает кладовщик.
const (
	ProblemReasonBreakage    = "breakage"     // бой
	ProblemReasonSpoilage    = "spoilage"     // порча
	ProblemReasonExpired     = "expired"      // просрок
	ProblemReasonForeignMark = "foreign_mark" // не наша марка ЧЗ
	ProblemReasonRetired     = "retired"      // марка ЧЗ выбыла из оборота (CZ-05)
	ProblemReasonOther       = "other"        // прочее
	// ProblemReasonNotFound — короб или марка не найдены пересчётом (P10-03). Заводит только
	// программа при подсчёте ячейки, на ТСД на выбор не предлагается.
	ProblemReasonNotFound = "not_found"
	// ProblemReasonRegrade — пересорт (ADHOC-53): ШК перепривязан к другому товару, и марки
	// ЧЗ этого GTIN со склада перешли на него. Заводит только перепривязка ШК.
	ProblemReasonRegrade = "regrade"
)

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
	// AllowPicking — из товара склада можно собирать заказы (галочка «разрешить сборку», P8-02).
	AllowPicking bool
}

// Действия решения офиса по проблеме (P6-07-3) — что программа делает с товаром. Значения лежат
// в БД под CHECK — менять только миграцией; названия видит офис у вариантов справочника (ADHOC-55).
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

// ProblemDecisions — все действия решения, в порядке показа (ADHOC-55): вариант решения
// справочника выбирает одно из них.
var ProblemDecisions = []string{
	ProblemDecisionWriteOff, ProblemDecisionPlace, ProblemDecisionSupplierReturn, ProblemDecisionRegrade,
}

// ProblemResolution — вариант решения проблемы (ADHOC-55): название для офиса и действие кода.
// Действие после заведения не меняется; неактивный вариант в выбор не попадает.
type ProblemResolution struct {
	ID       string
	Name     string
	Action   string
	IsActive bool
}

// ProblemReason — причина проблемы склада из справочника (ADHOC-55).
//
// Системную заводит программа (не наша марка, выбытие, «не найдено», пересорт): её не
// выключить. Manual — кладовщик выбирает её на ТСД; нет — ставит только программа.
// Resolutions — допустимые варианты решения, в порядке справочника, и неактивные тоже: портал
// показывает их в настройке, а решение берёт только активные.
type ProblemReason struct {
	Code            string
	Name            string
	IsSystem        bool
	Manual          bool
	CommentRequired bool
	IsActive        bool
	Resolutions     []string
}

// ProblemReasonInput — правка причины из портала; nil — поле не меняется.
type ProblemReasonInput struct {
	Code            string // пусто — новая причина
	Name            *string
	CommentRequired *bool
	IsActive        *bool
	Resolutions     *[]string
	By              string
}

// ProblemResolutionInput — правка варианта из портала; nil — поле не меняется. Action задаётся
// только при заведении.
type ProblemResolutionInput struct {
	ID       string // пусто — новый вариант
	Name     *string
	Action   string
	IsActive *bool
	By       string
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
	// ResolutionID — вариант решения из справочника (ADHOC-55); Decision — его действие, его
	// подставляет сервис. Прежний клиент шлёт одно действие — тогда берётся первый активный
	// вариант причины с этим действием.
	ResolutionID string
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
	// ReasonName — название причины из справочника (ADHOC-55).
	ReasonName string
	// Resolutions — активные варианты решения, допустимые при причине, в порядке справочника.
	Resolutions []ProblemResolution
	Comment     string
	Mark        string
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

	Status   string
	Decision string
	// ResolutionName — название выбранного варианта решения (ADHOC-55).
	ResolutionName string
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
	// ShipmentNumber — номер отгрузки возврата, «ВП» (ADHOC-55); 0 — не отгружен.
	ShipmentNumber int64

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

// Ошибки справочника причин и вариантов решения (ADHOC-55). Тексты — для экрана портала.
var (
	ErrInvalidProblemReason      = errors.New("причина задана неверно: нужно название до 100 символов и хотя бы один вариант решения")
	ErrProblemReasonNotFound     = errors.New("причина не найдена")
	ErrProblemReasonSystem       = errors.New("системную причину нельзя выключить")
	ErrProblemReasonNameTaken    = errors.New("причина с таким названием уже есть")
	ErrInvalidResolution         = errors.New("вариант решения задан неверно: нужно название до 100 символов и действие из списка")
	ErrResolutionNotFound        = errors.New("вариант решения не найден")
	ErrResolutionNameTaken       = errors.New("вариант решения с таким названием уже есть")
	ErrResolutionRegradeMismatch = errors.New("вариант «Провести пересорт» допустим только у причины «Пересорт», а у неё — только такие варианты")
)
