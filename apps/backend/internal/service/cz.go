package service

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"craftwms/internal/model"
)

// Ошибки ввода чтения марок.
var (
	// ErrCZNoCodes — не передано ни одного кода.
	ErrCZNoCodes = errors.New("no codes")
	// ErrCZTooManyCodes — кодов больше, чем читаем за раз.
	ErrCZTooManyCodes = errors.New("too many codes")
)

// czMaxCodes — сколько кодов читаем одним запросом. Транспортный короб — 24 марки (CZ-01);
// с запасом на паллету, но без выгрузки всего склада одним вызовом.
const czMaxCodes = 100

// gs — разделитель групп GS1 (0x1D): за ним в марке идёт криптохвост.
const gs = "\x1d"

// czClient — что сервису нужно от клиента True API (internal/trueapi.Client).
type czClient interface {
	CisesInfo(ctx context.Context, codes []string) ([]model.CisInfo, error)
	TokenExpiry() (time.Time, bool)
	SignerHealth(ctx context.Context) error
}

// CZMarks — что сервису нужно от хранилища марок (internal/repository.CZMarkRepository).
// Экспортирован, чтобы сборка в main держала переменную этого типа: без БД она остаётся
// настоящим nil, а не nil-указателем внутри интерфейса.
type CZMarks interface {
	GoodByGTIN(ctx context.Context, gtin string) (model.CZGoodRef, error)
	GoodRef(ctx context.Context, goodID string) (model.CZGoodRef, error)
	MarkByCIS(ctx context.Context, cis string) (model.CZMark, error)
	LoadUnitByCZCode(ctx context.Context, code string) (string, error)
	SetGoodCZMarked(ctx context.Context, goodID string, marked bool) error
}

// CZService — чтение Честного знака: состояние подписанта и токена (CZ-02), данные по скану
// марки или короба для ТСД (CZ-04).
//
// Как: без клиента (сокет подписанта не задан — локальный стек, тестовый стенд) сервис
// отвечает ErrCZNotConfigured, а не падает. Без хранилища марок (нет БД) скан отдаёт только
// данные ЧЗ — без товара справочника и места в WMS.
type CZService struct {
	client czClient
	marks  CZMarks
	// ownerINN — ИНН нашей организации в ЧЗ: марка с другим владельцем — расхождение (CZ-05).
	ownerINN string
}

// NewCZService — сервис поверх клиента True API и хранилища марок; client == nil — ЧЗ не
// настроен, marks == nil — без сведений WMS.
func NewCZService(client czClient, marks CZMarks) *CZService {
	return &CZService{client: client, marks: marks}
}

// WithOwnerINN задаёт ИНН нашей организации для сверки владельца марки (CZ-05). Пустой ИНН —
// владелец не сверяется: лучше пропустить проверку, чем объявить чужими все марки склада.
func (s *CZService) WithOwnerINN(inn string) *CZService {
	s.ownerINN = inn
	return s
}

// SetGoodCZMarked — правка признака «маркируемый» у товара (CZ-05, только admin).
//
// Обычно признак ставится сам — по привязке ШК из марки и по принятой марке (долг 16); правка
// нужна, когда товар пометили ошибочно или маркировку с него сняли. Связь с ЧЗ не нужна —
// только хранилище.
func (s *CZService) SetGoodCZMarked(ctx context.Context, goodID string, marked bool) error {
	if s.marks == nil {
		return model.ErrCZNotConfigured
	}
	return s.marks.SetGoodCZMarked(ctx, goodID, marked)
}

// Status — готов ли ЧЗ: подписант подписывает, токен есть и когда истекает.
//
// Подписант проверяется пробной подписью при каждом вызове: статус смотрит человек, и ему
// нужен ответ «сейчас», а не память о прошлом успехе.
func (s *CZService) Status(ctx context.Context) model.CZStatus {
	if s.client == nil {
		return model.CZStatus{}
	}
	st := model.CZStatus{Configured: true, SignerOK: true}
	if err := s.client.SignerHealth(ctx); err != nil {
		st.SignerOK, st.SignerError = false, err.Error()
	}
	if exp, ok := s.client.TokenExpiry(); ok {
		st.TokenValid, st.TokenExpiresAt = true, &exp
	}
	return st
}

// CisesInfo — данные марок и упаковок по кодам.
//
// Коды приводятся к ключу ЧЗ (ADR-0017): пробелы по краям срезаются, криптохвост после GS
// отбрасывается — сканер DT50S отдаёт марку целиком, а True API находит только КИ.
func (s *CZService) CisesInfo(ctx context.Context, codes []string) ([]model.CisInfo, error) {
	if s.client == nil {
		return nil, model.ErrCZNotConfigured
	}
	keys := make([]string, 0, len(codes))
	for _, c := range codes {
		c, _, _ = strings.Cut(strings.TrimSpace(c), gs)
		if c != "" {
			keys = append(keys, c)
		}
	}
	switch {
	case len(keys) == 0:
		return nil, ErrCZNoCodes
	case len(keys) > czMaxCodes:
		return nil, fmt.Errorf("%w: max %d", ErrCZTooManyCodes, czMaxCodes)
	}
	return s.client.CisesInfo(ctx, keys)
}
