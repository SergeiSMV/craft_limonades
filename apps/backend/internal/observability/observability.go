// Package observability — отправка ошибок бэкенда в Bugsink (ADHOC-42).
//
// Что: ошибки журнала (slog, уровень error) и паники HTTP-запросов уходят событиями в Bugsink —
// свой сервер, совместимый с Sentry, поэтому клиент — штатный sentry-go.
// Зачем: до этого ошибка 500 оставалась строкой в journal сервера, и узнавали о ней по жалобе
// кладовщика. Событие несёт стек, запрос, пользователя и группируется: повтор той же ошибки —
// счётчик, а не новое письмо.
// Как: обёртка над обработчиком slog ([Handler]) — места, где бэкенд уже пишет `slog.Error`,
// отправляют событие без правок; middleware ([Middleware]) даёт каждому запросу свой контекст
// (запрос, request_id) и ловит паники. Без DSN всё выключено: dev, тесты и стенд — как раньше.
package observability

import (
	"context"
	"errors"
	"time"

	"github.com/getsentry/sentry-go"
)

// Options — настройки отправки. DSN пуст — отправка выключена.
type Options struct {
	DSN         string // адрес проекта Bugsink (env SENTRY_DSN)
	Environment string // окружение: prod, stand … (env SENTRY_ENVIRONMENT)
	Release     string // версия сборки (env SENTRY_RELEASE); пусто — без версии

	// Transport — только для тестов: перехват событий вместо отправки по сети.
	Transport sentry.Transport
}

// Init включает отправку ошибок. Возвращает false, если DSN не задан — тогда [Handler] и
// [Middleware] ничего не отправляют и почти ничего не стоят.
//
// SendDefaultPII выключен: в событие не попадают заголовки авторизации, cookie и IP клиента.
// Пользователь называется только идентификатором и ролью — их кладёт [Handler] из контекста.
func Init(o Options) (bool, error) {
	if o.DSN == "" {
		return false, nil
	}
	err := sentry.Init(sentry.ClientOptions{
		Dsn:              o.DSN,
		Environment:      o.Environment,
		Release:          o.Release,
		AttachStacktrace: true,
		SendDefaultPII:   false,
		Transport:        o.Transport,
	})
	if err != nil {
		return false, err
	}
	return true, nil
}

// Flush дожидается отправки накопленных событий — при остановке сервиса, иначе ошибки,
// случившиеся перед самым SIGTERM, пропали бы вместе с процессом.
func Flush(timeout time.Duration) bool {
	if sentry.CurrentHub().Client() == nil {
		return true
	}
	return sentry.Flush(timeout)
}

// enabled — отправка включена.
func enabled() bool { return sentry.CurrentHub().Client() != nil }

// hubFrom — hub запроса из контекста, а вне запроса — общий.
func hubFrom(ctx context.Context) *sentry.Hub {
	if ctx != nil {
		if hub := sentry.GetHubFromContext(ctx); hub != nil {
			return hub
		}
	}
	return sentry.CurrentHub()
}

// isAbort — штатный обрыв ответа (клиент ушёл): net/http сам глушит такую панику, это не ошибка.
func isAbort(v any) bool {
	err, ok := v.(error)
	return ok && errors.Is(err, errAbortHandler)
}
