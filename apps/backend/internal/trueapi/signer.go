// Package trueapi - клиент True API Честного знака (CZ-02): токен, его кэш и чтение марок.
//
// Зачем: WMS читает данные марок (ADR-0017), а True API пускает только по токену, который
// выдаётся в обмен на строку auth/key, подписанную КЭП. Подписывает служба cz-signer на хосте,
// клиент ходит к ней через unix-сокет, а всё остальное - токен, кэш, обновление - делает сам.
package trueapi

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"

	"craftwms/internal/model"
)

// Signer - подпись строки auth/key. В службе - SocketSigner, в тестах - подстановка.
type Signer interface {
	// Sign - присоединённая подпись CAdES-BES (DER) над data.
	Sign(ctx context.Context, data []byte) ([]byte, error)
	// Health - подписант жив и может подписывать (пробная подпись).
	Health(ctx context.Context) error
}

// signerTimeout - предел запроса к подписанту: его собственный предел на cryptcp (30 с) плюс запас.
const signerTimeout = 40 * time.Second

// SocketSigner - подписант cz-signer за unix-сокетом (`internal/czsigner`).
type SocketSigner struct {
	http *http.Client
}

// NewSocketSigner - клиент подписанта по пути сокета. Хост в URL условный: соединение
// всегда идёт в сокет, сеть не участвует.
func NewSocketSigner(socket string) *SocketSigner {
	return &SocketSigner{http: &http.Client{
		Timeout: signerTimeout,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, "unix", socket)
			},
		},
	}}
}

// Sign отправляет data подписанту и возвращает подпись. Любой сбой - ErrCZSignerUnavailable:
// для вызывающего неважно, лежит служба или не открылся ключ, лечится это на сервере.
func (s *SocketSigner) Sign(ctx context.Context, data []byte) ([]byte, error) {
	return s.do(ctx, http.MethodPost, "/sign", data)
}

// Health - пробная подпись на стороне подписанта.
func (s *SocketSigner) Health(ctx context.Context) error {
	_, err := s.do(ctx, http.MethodGet, "/health", nil)
	return err
}

// do - запрос к подписанту; не-200 и ошибки соединения сводятся к ErrCZSignerUnavailable.
func (s *SocketSigner) do(ctx context.Context, method, path string, body []byte) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, method, "http://cz-signer"+path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	resp, err := s.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", model.ErrCZSignerUnavailable, err)
	}
	defer func() { _ = resp.Body.Close() }()
	out, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, fmt.Errorf("%w: read: %v", model.ErrCZSignerUnavailable, err)
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%w: HTTP %d: %s", model.ErrCZSignerUnavailable,
			resp.StatusCode, strings.TrimSpace(string(out)))
	}
	return out, nil
}
