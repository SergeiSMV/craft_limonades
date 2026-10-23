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
	RequestedCis   string   `json:"requestedCis"`   // код, который спрашивали
	Cis            string   `json:"cis"`            // КИ марки или код агрегата
	Gtin           string   `json:"gtin"`           // GTIN; у транспортного короба пусто
	ProductName    string   `json:"productName"`    // наименование
	ProductGroup   string   `json:"productGroup"`   // товарная группа: beer, softdrinks, …
	PackageType    string   `json:"packageType"`    // UNIT, GROUP, BOX — вид упаковки
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
