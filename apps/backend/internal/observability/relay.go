package observability

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/getsentry/sentry-go"
)

// ErrBadEnvelope — тело не похоже на конверт Sentry: первая строка не JSON-объект.
var ErrBadEnvelope = errors.New("bad sentry envelope")

// relayTimeout — сколько ждём Bugsink. Он в той же сети compose и отвечает за миллисекунды;
// дольше — значит, лежит, и клиенту лучше повторить позже, чем держать соединение.
const relayTimeout = 10 * time.Second

// Relay пересылает конверты событий приложений (ТСД и портала) в проект Bugsink `app`
// (ADHOC-47).
//
// Что: конверт приходит на бэкенд по пути протокола Sentry, с фиктивным ключом из DSN, который
// клиент строит из адреса API. Relay убирает этот ключ из конверта и отправляет его в Bugsink
// по внутреннему адресу с ключом проекта.
// Зачем: клиентам не нужен настоящий DSN в сборке (ключ меняется без пересборки, стенд и
// локальный стек отправку не включают), порталу — CORS, хостовому nginx — новый путь.
// Как: Bugsink берёт ключ из `dsn` в заголовке конверта, если он там есть, иначе — из
// X-Sentry-Auth (проверено на Bugsink 2). Поэтому `dsn` из заголовка удаляется, а ключ проекта
// ставится в X-Sentry-Auth.
type Relay struct {
	endpoint string // адрес приёма конвертов проекта в Bugsink
	auth     string // заголовок X-Sentry-Auth с ключом проекта
	client   *http.Client
}

// NewRelay собирает пересылку по DSN проекта `app` (env CLIENT_SENTRY_DSN). Пустой DSN —
// пересылки нет (nil): события клиентов отбрасываются.
func NewRelay(dsn string) (*Relay, error) {
	if dsn == "" {
		return nil, nil
	}
	d, err := sentry.NewDsn(dsn)
	if err != nil {
		return nil, fmt.Errorf("CLIENT_SENTRY_DSN: %w", err)
	}
	return &Relay{
		endpoint: d.GetAPIURL().String(),
		auth:     "Sentry sentry_version=7, sentry_client=craft-wms-relay/1, sentry_key=" + d.GetPublicKey(),
		client:   &http.Client{Timeout: relayTimeout},
	}, nil
}

// Forward отправляет конверт (уже распакованный) в Bugsink и возвращает его ответ как есть —
// код и заголовки ограничения частоты клиент SDK разбирает сам. Тело ответа закрывает
// вызывающий.
func (r *Relay) Forward(ctx context.Context, envelope []byte) (*http.Response, error) {
	body, err := StripEnvelopeDSN(envelope)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, r.endpoint, bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("запрос в Bugsink: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-sentry-envelope")
	req.Header.Set("X-Sentry-Auth", r.auth)
	resp, err := r.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("отправить конверт в Bugsink: %w", err)
	}
	return resp, nil
}

// StripEnvelopeDSN убирает поле `dsn` из заголовка конверта — первой строки, JSON-объекта.
// Остальные строки (заголовки и тела элементов) не трогаются: тела бывают двоичными.
func StripEnvelopeDSN(envelope []byte) ([]byte, error) {
	head, rest, found := bytes.Cut(envelope, []byte("\n"))
	var header map[string]json.RawMessage
	if err := json.Unmarshal(head, &header); err != nil || header == nil {
		return nil, ErrBadEnvelope
	}
	if _, ok := header["dsn"]; !ok {
		return envelope, nil
	}
	delete(header, "dsn")
	clean, err := json.Marshal(header)
	if err != nil {
		return nil, fmt.Errorf("заголовок конверта: %w", err)
	}
	if !found {
		return clean, nil
	}
	out := make([]byte, 0, len(clean)+1+len(rest))
	out = append(out, clean...)
	out = append(out, '\n')
	return append(out, rest...), nil
}
