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
	AggregateCode       string // упаковка ЧЗ, в которой марка пришла
	LoadUnitCellID      string // чтение: ячейка короба марки; пусто — россыпь или короб не размещён
}

// CZAggregateContents — состав агрегата ЧЗ: вложенные упаковки и марки, числящиеся в нём.
type CZAggregateContents struct {
	Aggregate CZAggregate
	Groups    []CZAggregate
	Marks     []CZMark
}
