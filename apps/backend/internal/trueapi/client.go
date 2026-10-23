package trueapi

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"craftwms/internal/model"
)

// Сроки токена. True API выдаёт токен примерно на 10 часов (CZ-01).
const (
	// DefaultRefreshBefore — за сколько до истечения токен обновляется заранее.
	DefaultRefreshBefore = time.Hour
	// expiryMargin — старый токен ещё годен, если до истечения больше этого: когда обновить
	// не вышло, работаем на нём, а не останавливаем чтение марок.
	expiryMargin = time.Minute
	// fallbackTTL — срок, если в токене не нашлось exp: меньше настоящего, чтобы не опоздать.
	fallbackTTL = 9 * time.Hour
	// apiTimeout — предел одного запроса к True API.
	apiTimeout = 30 * time.Second
	// maxBody — предел читаемого ответа True API.
	maxBody = 8 << 20
)

// Options — настройки клиента.
type Options struct {
	BaseURL       string        // напр. https://markirovka.crpt.ru/api/v3/true-api
	Signer        Signer        // подписант строки auth/key
	RefreshBefore time.Duration // 0 — DefaultRefreshBefore
	HTTP          *http.Client  // nil — клиент с apiTimeout
	Log           *slog.Logger  // nil — slog.Default()
	Now           func() time.Time
}

// Client — клиент True API: токен организации в памяти, обновление до истечения, чтение марок.
//
// Как: токен живёт в памяти процесса (бэкенд один, а после рестарта новый получается сам, без
// человека). Обновление идёт под mutex: параллельные запросы ждут одно обновление, а не
// подписывают каждый своё. Фоновый Run обновляет токен заранее, чтобы запрос с ТСД не ждал
// подписи, а сбой входа был виден в журнале (и в Bugsink) сразу, а не на складе.
type Client struct {
	base          string
	signer        Signer
	refreshBefore time.Duration
	http          *http.Client
	log           *slog.Logger
	now           func() time.Time

	mu     sync.Mutex
	token  string
	expiry time.Time
}

// New собирает клиент; пустые поля Options получают значения по умолчанию.
func New(o Options) *Client {
	c := &Client{
		base:          strings.TrimRight(o.BaseURL, "/"),
		signer:        o.Signer,
		refreshBefore: o.RefreshBefore,
		http:          o.HTTP,
		log:           o.Log,
		now:           o.Now,
	}
	if c.refreshBefore <= 0 {
		c.refreshBefore = DefaultRefreshBefore
	}
	if c.http == nil {
		c.http = &http.Client{Timeout: apiTimeout}
	}
	if c.log == nil {
		c.log = slog.Default()
	}
	if c.now == nil {
		c.now = time.Now
	}
	return c
}

// TokenExpiry — когда истекает токен в памяти; ok=false — токена нет.
func (c *Client) TokenExpiry() (expiry time.Time, ok bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.expiry, c.token != ""
}

// SignerHealth — подписант жив и подписывает.
func (c *Client) SignerHealth(ctx context.Context) error { return c.signer.Health(ctx) }

// Token возвращает действующий токен, при необходимости получая новый.
//
// Свежий токен (до порога обновления) отдаётся из памяти. Иначе — вход заново; если вход не
// удался, а старый токен ещё годен, отдаётся старый: сбой подписанта не должен сразу
// останавливать чтение марок — фоновое обновление попробует снова.
func (c *Client) Token(ctx context.Context) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	if c.token != "" && now.Before(c.expiry.Add(-c.refreshBefore)) {
		return c.token, nil
	}
	token, expiry, err := c.signIn(ctx)
	if err != nil {
		if c.token != "" && now.Before(c.expiry.Add(-expiryMargin)) {
			c.log.Warn("true api token refresh failed, using current token",
				"error", err, "expires_at", c.expiry)
			return c.token, nil
		}
		return "", err
	}
	c.token, c.expiry = token, expiry
	c.log.Info("true api token obtained", "expires_at", expiry)
	return token, nil
}

// invalidate забывает токен, если он всё ещё тот, на который True API ответил 401.
func (c *Client) invalidate(token string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.token == token {
		c.token, c.expiry = "", time.Time{}
	}
}

// signIn — вход в True API: auth/key → подпись строки → simpleSignIn.
func (c *Client) signIn(ctx context.Context) (string, time.Time, error) {
	var key struct {
		UUID string `json:"uuid"`
		Data string `json:"data"`
	}
	if err := c.call(ctx, http.MethodGet, "/auth/key", "", nil, &key); err != nil {
		return "", time.Time{}, err
	}
	if key.UUID == "" || key.Data == "" {
		return "", time.Time{}, fmt.Errorf("%w: auth/key without uuid or data", model.ErrCZUnavailable)
	}

	sig, err := c.signer.Sign(ctx, []byte(key.Data))
	if err != nil {
		return "", time.Time{}, err
	}

	body, _ := json.Marshal(map[string]string{
		"uuid": key.UUID,
		"data": base64.StdEncoding.EncodeToString(sig),
	})
	var resp struct {
		Token string `json:"token"`
	}
	if err := c.call(ctx, http.MethodPost, "/auth/simpleSignIn", "", body, &resp); err != nil {
		// Любой 4xx на входе — отказ ЧЗ в подписи (сертификат, МЧД, роль), а не «нет марки».
		var se *statusError
		if errors.As(err, &se) && se.code < 500 {
			return "", time.Time{}, fmt.Errorf("%w: %v", model.ErrCZAuthFailed, err)
		}
		return "", time.Time{}, err
	}
	if resp.Token == "" {
		return "", time.Time{}, fmt.Errorf("%w: simpleSignIn without token", model.ErrCZAuthFailed)
	}

	expiry, ok := tokenExpiry(resp.Token)
	if !ok {
		expiry = c.now().Add(fallbackTTL)
		c.log.Warn("true api token without exp, assuming fallback ttl", "ttl", fallbackTTL)
	}
	return resp.Token, expiry, nil
}

// CisesInfo — данные марок и упаковок по кодам (`POST /cises/info`).
//
// Коды — КИ без криптохвоста или `00`+SSCC (ADR-0017). На 401 токен сбрасывается и запрос
// повторяется один раз с новым: ЧЗ мог отозвать токен раньше срока.
func (c *Client) CisesInfo(ctx context.Context, codes []string) ([]model.CisInfo, error) {
	body, err := json.Marshal(codes)
	if err != nil {
		return nil, err
	}
	var raw []json.RawMessage
	for attempt := 0; ; attempt++ {
		token, err := c.Token(ctx)
		if err != nil {
			return nil, err
		}
		err = c.call(ctx, http.MethodPost, "/cises/info", token, body, &raw)
		var se *statusError
		if errors.As(err, &se) && se.code == http.StatusUnauthorized && attempt == 0 {
			c.invalidate(token)
			continue
		}
		if err != nil {
			return nil, err
		}
		break
	}
	return parseCisesInfo(raw)
}

// parseCisesInfo разбирает ответ cises/info: массив `{"cisInfo": {...}, "errorMessage": ...}`.
func parseCisesInfo(raw []json.RawMessage) ([]model.CisInfo, error) {
	out := make([]model.CisInfo, 0, len(raw))
	for _, item := range raw {
		var wrap struct {
			CisInfo      json.RawMessage `json:"cisInfo"`
			ErrorMessage string          `json:"errorMessage"`
		}
		if err := json.Unmarshal(item, &wrap); err != nil {
			return nil, fmt.Errorf("%w: cises/info: %v", model.ErrCZUnavailable, err)
		}
		var info model.CisInfo
		if len(wrap.CisInfo) > 0 {
			if err := json.Unmarshal(wrap.CisInfo, &info); err != nil {
				return nil, fmt.Errorf("%w: cises/info: %v", model.ErrCZUnavailable, err)
			}
		}
		if wrap.ErrorMessage != "" {
			info.ErrorMessage = wrap.ErrorMessage
		}
		info.Raw = item
		out = append(out, info)
	}
	return out, nil
}

// statusError — True API ответил не-2xx; код нужен, чтобы отличить 401 от остального.
type statusError struct {
	code int
	body string
}

func (e *statusError) Error() string { return fmt.Sprintf("HTTP %d: %s", e.code, e.body) }

// call — один запрос к True API с разбором JSON-ответа в out.
//
// Ошибки: сеть, таймаут и 5xx — ErrCZUnavailable; 403 — ErrCZNoContract; 404 —
// ErrCZNotFound; прочее — *statusError (по нему вызывающий решает, что делать с 401).
// Токен в журнал и в текст ошибки не попадает.
func (c *Client) call(ctx context.Context, method, path, token string, body []byte, out any) error {
	req, err := http.NewRequestWithContext(ctx, method, c.base+path, bytes.NewReader(body))
	if err != nil {
		return err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json;charset=UTF-8")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("%w: %s: %v", model.ErrCZUnavailable, path, err)
	}
	defer func() { _ = resp.Body.Close() }()
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxBody))
	if err != nil {
		return fmt.Errorf("%w: %s: read: %v", model.ErrCZUnavailable, path, err)
	}

	se := &statusError{code: resp.StatusCode, body: snippet(data)}
	switch {
	case resp.StatusCode >= 500:
		return fmt.Errorf("%w: %s: %v", model.ErrCZUnavailable, path, se)
	case resp.StatusCode == http.StatusForbidden && token != "":
		return fmt.Errorf("%w: %s", model.ErrCZNoContract, se.body)
	case resp.StatusCode == http.StatusNotFound && token != "":
		return fmt.Errorf("%w: %s", model.ErrCZNotFound, se.body)
	case resp.StatusCode < 200 || resp.StatusCode > 299:
		return se
	}
	if err := json.Unmarshal(data, out); err != nil {
		return fmt.Errorf("%w: %s: bad json: %v", model.ErrCZUnavailable, path, err)
	}
	return nil
}

// snippet — начало тела ответа для текста ошибки: ЧЗ объясняет отказ в теле.
func snippet(b []byte) string {
	s := strings.TrimSpace(string(b))
	if len(s) > 300 {
		s = s[:300] + "…"
	}
	return s
}

// tokenExpiry достаёт exp из JWT-токена ЧЗ. Подпись не проверяется: токен пришёл от True API
// по TLS, и срок нужен только чтобы знать, когда обновлять.
func tokenExpiry(token string) (time.Time, bool) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return time.Time{}, false
	}
	payload, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(parts[1], "="))
	if err != nil {
		return time.Time{}, false
	}
	var claims struct {
		Exp int64 `json:"exp"`
	}
	if err := json.Unmarshal(payload, &claims); err != nil || claims.Exp == 0 {
		return time.Time{}, false
	}
	return time.Unix(claims.Exp, 0), true
}
