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

// CZService — чтение Честного знака (CZ-02): состояние подписанта и токена, данные марок.
//
// Что: сейчас — только для администратора (проверка настройки); складские сценарии с марками
// придут в CZ-03…CZ-05 и будут ходить сюда же.
// Как: без клиента (сокет подписанта не задан — локальный стек, тестовый стенд) сервис
// отвечает ErrCZNotConfigured, а не падает.
type CZService struct {
	client czClient
}

// NewCZService — сервис поверх клиента True API; client == nil — ЧЗ не настроен.
func NewCZService(client czClient) *CZService {
	return &CZService{client: client}
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
