package model

import (
	"encoding/json"
	"errors"
	"time"
)

// Ошибки-сигналы чтения Честного знака (CZ-02). Различаются, потому что лечатся по-разному:
// подписант — на сервере WMS, договор по группе — в ЧЗ, недоступность True API — ожиданием.
var (
	// ErrCZNotConfigured — Честный знак на этом стенде не настроен (нет сокета подписанта).
	ErrCZNotConfigured = errors.New("chestny znak is not configured")
	// ErrCZSignerUnavailable — подписант не отвечает или не смог подписать: служба остановлена,
	// нет ключа, неверный пароль копии, истекла лицензия КриптоПро.
	ErrCZSignerUnavailable = errors.New("chestny znak signer unavailable")
	// ErrCZAuthFailed — True API не выдал токен на подписанную строку: сертификат, МЧД, роль.
	ErrCZAuthFailed = errors.New("chestny znak sign-in rejected")
	// ErrCZUnavailable — True API недоступен: сеть, таймаут, ответ 5xx.
	ErrCZUnavailable = errors.New("chestny znak api unavailable")
	// ErrCZNoContract — у организации нет договора по товарной группе марки (403, напр. вода).
	ErrCZNoContract = errors.New("no chestny znak contract for product group")
	// ErrCZNotFound — марки нет в ЧЗ (404); в том числе код с криптохвостом, а не КИ.
	ErrCZNotFound = errors.New("chestny znak code not found")
)

// CisInfo — данные марки или упаковки из True API (`POST /cises/info`).
//
// Что: поля, которые WMS понадобятся на приёмке и размещении (CZ-03…CZ-05); всё остальное
// остаётся в Raw. Даты — строками, как их отдаёт ЧЗ: разбирать их будет CZ-04, когда партия
// станет считаться по дате производства единицы (ADR-0017).
type CisInfo struct {
	RequestedCis string `json:"requestedCis"`       // код, который спрашивали
	Cis          string `json:"cis"`                // КИ марки или код агрегата
	Gtin         string `json:"gtin"`               // GTIN; у транспортного короба пусто
	ProductName  string `json:"productName"`        // наименование
	ProductGroup string `json:"productGroup"`       // товарная группа: beer, softdrinks, …
	PackageType  string `json:"generalPackageType"` // UNIT, GROUP, BOX — вид упаковки
	// PackageLevel — уровень упаковки: UNIT у единицы, LEVEL1… у агрегатов. Вид в нём не
	// виден — транспортный короб пива пришёл как LEVEL1 (сверено на проде, CZ-02).
	PackageLevel   string   `json:"packageType"`
	Status         string   `json:"status"`         // статус в обороте: INTRODUCED, …
	OwnerInn       string   `json:"ownerInn"`       // ИНН владельца
	OwnerName      string   `json:"ownerName"`      // владелец
	ProducedDate   string   `json:"producedDate"`   // дата производства (у упаковки — агрегации)
	ExpirationDate string   `json:"expirationDate"` // срок годности
	Parent         string   `json:"parent"`         // упаковка, в которой лежит марка
	Child          []string `json:"child"`          // КИ вложенных марок

	// ErrorMessage — отказ ЧЗ по этому коду в пакетном ответе (остальные коды могут прийти).
	ErrorMessage string `json:"errorMessage,omitempty"`
	// Raw — ответ ЧЗ по коду целиком: для проверки и для полей, которых WMS ещё не знает.
	Raw json.RawMessage `json:"raw,omitempty"`
}

// CZStatus — состояние чтения Честного знака для администратора (`GET /admin/cz/status`).
type CZStatus struct {
	Configured     bool       // сокет подписанта задан
	SignerOK       bool       // подписант сделал пробную подпись
	SignerError    string     // почему подписант не готов; пусто — готов
	TokenValid     bool       // в памяти есть токен True API
	TokenExpiresAt *time.Time // когда он истекает; nil — токена нет
}

// Ошибки хранения марок и агрегатов (CZ-03).
var (
	// ErrCZMarkNotFound — марки с таким КИ на складе не было.
	ErrCZMarkNotFound = errors.New("chestny znak mark not found")
	// ErrCZAggregateNotFound — агрегата ЧЗ с таким кодом в WMS нет.
	ErrCZAggregateNotFound = errors.New("chestny znak aggregate not found")
	// ErrCZMarkExists — марка уже числится в WMS: марка уникальна, второй раз её не принять.
	ErrCZMarkExists = errors.New("chestny znak mark already exists")
	// ErrCZAggregateExists — агрегат с таким кодом уже заведён.
	ErrCZAggregateExists = errors.New("chestny znak aggregate already exists")
	// ErrCZUnknownGTIN — GTIN марки не найден среди ШК справочника: товар неизвестен.
	ErrCZUnknownGTIN = errors.New("gtin not found in goods barcodes")
	// ErrCZGoodNotFound — товара, которому правят признак «маркируемый», нет (CZ-05).
	ErrCZGoodNotFound = errors.New("good not found")
	// ErrCZMarkGoodMismatch — GTIN марки — ШК другого товара, не товара строки приёмки (CZ-05).
	ErrCZMarkGoodMismatch = errors.New("chestny znak mark belongs to another good")
	// ErrCZMarksExceedQty — марок в строке приёмки больше, чем её количество (CZ-05).
	ErrCZMarksExceedQty = errors.New("more chestny znak marks than line quantity")
	// ErrCZMarksRequired — маркируемый товар россыпью и из короба двигается только марками
	// (CZ-06): иначе неизвестно, какие именно единицы переехали.
	ErrCZMarksRequired = errors.New("marked goods move only by chestny znak marks")
	// ErrCZMarksQtyMismatch — марок в строке не столько, сколько единиц она двигает (CZ-06).
	ErrCZMarksQtyMismatch = errors.New("chestny znak marks count differs from line quantity")
	// ErrCZMarkNotAtSource — марки нет там, откуда строка берёт товар, или она уже не на
	// складе (CZ-06).
	ErrCZMarkNotAtSource = errors.New("chestny znak mark is not at the line source")
	// ErrCZMarkBatchMismatch — марка другого товара или другой партии, не строки (CZ-06).
	ErrCZMarkBatchMismatch = errors.New("chestny znak mark belongs to another good or batch")
	// ErrCZReturnMarksIncomplete — у позиции возврата отсканированы не все её марки (CZ-06,
	// долг 30): к поставщику уезжают конкретные экземпляры, и все они должны быть названы.
	ErrCZReturnMarksIncomplete = errors.New("not all chestny znak marks of the return position were scanned")
	// ErrCZReturnMarkForeign — отсканированная марка не числится ни в одной позиции сеанса
	// возврата (CZ-06).
	ErrCZReturnMarkForeign = errors.New("chestny znak mark is not in the return positions")
)

// Вид агрегата ЧЗ — generalPackageType ответа ЧЗ.
const (
	CZAggregateBox   = "BOX"   // транспортный короб; в WMS — ГЕ, узнаётся по SSCC
	CZAggregateGroup = "GROUP" // групповая упаковка (6X, 12X)
)

// Статус марки в WMS.
const (
	CZMarkInStock    = "in_stock"    // на складе
	CZMarkShipped    = "shipped"     // отгружена клиенту
	CZMarkWrittenOff = "written_off" // списана по решению офиса
	CZMarkReturned   = "returned"    // возвращена поставщику
)

// CZAggregate — агрегат ЧЗ на складе (`cz_aggregates`).
type CZAggregate struct {
	Code       string     // `00`+SSCC у короба, КИ у групповой упаковки
	Kind       string     // CZAggregateBox / CZAggregateGroup
	ParentCode string     // в какой упаковке ЧЗ лежит; пусто — верхний уровень
	LoadUnitID string     // ГЕ, которой является короб; пусто у групповой упаковки
	OpenedAt   *time.Time // вскрыт; nil — целый
}

// CZMark — марка ЧЗ на складе (`cz_marks`).
//
// Место — ровно одно, пока марка на складе: LoadUnitID (в коробе) или CellID с
// InternalWarehouseID (россыпью). LoadUnitCellID — только для чтения: где сейчас лежит короб
// марки; хранится оно у ГЕ, а не у марки.
type CZMark struct {
	CIS                 string // КИ — часть кода до GS
	GTIN                string // вычисляется базой из КИ; при записи не нужен
	GoodID              string
	BatchID             string
	Status              string // CZMarkInStock, …
	LoadUnitID          string
	CellID              string
	InternalWarehouseID string
	AggregateCode       string    // упаковка ЧЗ, в которой марка пришла
	LoadUnitCellID      string    // чтение: ячейка короба марки; пусто — россыпь или короб не размещён
	ReceivedAt          time.Time // чтение: когда марка появилась в WMS
	CellAddress         string    // чтение: адрес ячейки, где марка лежит (короба или своей)
}

// ReceiptMark — марка ЧЗ в строке приёмки (CZ-05), как её прочитал скан на ТСД.
//
// AggregateCode — короб ЧЗ или групповая упаковка той же приёмки, в которой марка пришла;
// пусто — марка россыпью. Discrepancy — расхождение, которое отметил скан (CZDiscrepancy*):
// такая марка принимается и при проводке уходит проблемой склада в «Изолятор».
type ReceiptMark struct {
	CIS           string
	AggregateCode string
	Discrepancy   string
}

// CZAggregateContents — состав агрегата ЧЗ: вложенные упаковки и марки, числящиеся в нём.
type CZAggregateContents struct {
	Aggregate CZAggregate
	Groups    []CZAggregate
	Marks     []CZMark
}

// ErrCZBadCode — код не похож ни на марку (`01`+GTIN+`21`…), ни на код короба (`00`+SSCC).
var ErrCZBadCode = errors.New("not a chestny znak code")

// CZGoodRef — товар справочника, найденный по GTIN марки.
type CZGoodRef struct {
	ID   string
	Name string
}

// CZScan — что ТСД узнаёт по скану марки или кода агрегата (CZ-04).
//
// Что: данные ЧЗ по коду, товар справочника, что о коде знает WMS и, для упаковки, её состав
// до единиц. Наименование ЧЗ и товар справочника — разные поля: на марке название может не
// совпадать с номенклатурой 1С, товар определяет привязка ШК.
type CZScan struct {
	Code string  // код, приведённый к ключу ЧЗ
	Info CisInfo // ответ ЧЗ по коду

	Good *CZGoodRef // товар по GTIN; nil — GTIN незнаком (или у упаковки нет GTIN)
	// BindBarcode — какой ШК привязать к товару, если GTIN незнаком: EAN-13 — GTIN-14 без
	// ведущего нуля, чтобы и обычный скан ШК той же бутылки находил товар.
	BindBarcode string
	// UnboundBarcode — марка числится в WMS, а её ШК (EAN-13 из GTIN) ни к какому товару не
	// привязан (ADHOC-53): товар тогда — из записи марки, ТСД предлагает вернуть привязку.
	UnboundBarcode string

	Mark       *CZMark // марка в WMS: место, статус, приход; nil — не числится
	LoadUnitID string  // короб в WMS — это ГЕ; пусто — короб не принят

	// Discrepancy — расхождение кода с ЧЗ (CZ-05): CZDiscrepancyForeignMark — владелец не наша
	// организация, CZDiscrepancyRetired — не в обороте; пусто — расхождения нет.
	Discrepancy string

	Composition []CZCompositionLine // состав упаковки до единиц, по товару и партии
	Units       int                 // всего единиц в составе
	Unreadable  []string            // вложенные коды, по которым ЧЗ отказал

	// Groups — групповые упаковки внутри упаковки, с вложенностью (CZ-05): приёмка заводит их
	// агрегатами. ParentCode — сканированный код или другая упаковка из Groups.
	Groups []CZAggregate
	// Parents — КИ единицы → упаковка, в которой она лежит: сканированный код или упаковка
	// из Groups (CZ-05). Приёмка пишет его марке как aggregate_code.
	Parents map[string]string
}

// CZCompositionLine — строка состава: единицы одного GTIN и одной даты производства (партии).
type CZCompositionLine struct {
	GTIN         string
	ProductName  string     // наименование по ЧЗ
	Good         *CZGoodRef // товар справочника; nil — GTIN незнаком
	ProducedDate string     // дата производства единицы, YYYY-MM-DD — партия (ADR-0017)
	Count        int
	CIS          []string // КИ единиц строки
	Discrepancy  string   // расхождение единиц строки с ЧЗ; пусто — нет
}

// Расхождения марки с ЧЗ на приёмке (CZ-05) — совпадают с причинами проблемы склада, в которую
// такая марка уходит при проводке.
const (
	CZDiscrepancyForeignMark = ProblemReasonForeignMark // владелец марки — не наша организация
	CZDiscrepancyRetired     = ProblemReasonRetired     // марка не в обороте
)
