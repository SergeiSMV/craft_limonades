package observability

import (
	"context"
	"errors"
	"log/slog"

	"github.com/getsentry/sentry-go"
)

// UserFunc достаёт пользователя запроса из контекста: идентификатор и роль. Передаётся снаружи
// (middleware аутентификации), чтобы этот пакет не зависел от неё.
type UserFunc func(ctx context.Context) (id, role string, ok bool)

// Handler - обработчик slog поверх обычного: пишет запись как раньше и, если это ошибка,
// отправляет её событием в Bugsink (ADHOC-42).
//
// Почему свой, а не `sentry-go/slog`: тот шлёт записи «логами Sentry», а Bugsink принимает
// события ошибок. Здесь запись уровня error и выше - событие: сообщение записи, ошибка из
// атрибута `error` (её тип и цепочка - заголовок события), остальные атрибуты - контекст
// «log», пользователь - из контекста запроса.
type Handler struct {
	next   slog.Handler
	user   UserFunc
	attrs  []slog.Attr
	prefix string // группы slog - префиксом имени атрибута
}

// NewHandler оборачивает [next]. [user] может быть nil - тогда пользователя в событии нет.
func NewHandler(next slog.Handler, user UserFunc) *Handler {
	return &Handler{next: next, user: user}
}

// Enabled - как у обёрнутого: что не пишется в журнал, то и не отправляется.
func (h *Handler) Enabled(ctx context.Context, level slog.Level) bool {
	return h.next.Enabled(ctx, level)
}

// Handle пишет запись в журнал и отправляет ошибку. Отправка не мешает записи: журнал -
// основной след, событие - уведомление поверх.
func (h *Handler) Handle(ctx context.Context, r slog.Record) error {
	err := h.next.Handle(ctx, r)
	if r.Level >= slog.LevelError && enabled() {
		h.capture(ctx, r)
	}
	return err
}

// WithAttrs - атрибуты логгера (`log.With(...)`) попадают и в событие.
func (h *Handler) WithAttrs(attrs []slog.Attr) slog.Handler {
	c := *h
	c.next = h.next.WithAttrs(attrs)
	c.attrs = append(append([]slog.Attr{}, h.attrs...), prefixed(h.prefix, attrs)...)
	return &c
}

// WithGroup - группа становится префиксом имён атрибутов события.
func (h *Handler) WithGroup(name string) slog.Handler {
	c := *h
	c.next = h.next.WithGroup(name)
	c.prefix = h.prefix + name + "."
	return &c
}

// capture собирает событие из записи и отправляет его через hub запроса.
func (h *Handler) capture(ctx context.Context, r slog.Record) {
	event := sentry.NewEvent()
	event.Level = sentry.LevelError
	event.Message = r.Message

	fields := sentry.Context{}
	var cause error
	add := func(a slog.Attr) {
		v := a.Value.Resolve()
		if e, ok := v.Any().(error); ok && cause == nil {
			cause = e
		}
		fields[a.Key] = v.String()
	}
	for _, a := range h.attrs {
		add(a)
	}
	r.Attrs(func(a slog.Attr) bool {
		add(slog.Attr{Key: h.prefix + a.Key, Value: a.Value})
		return true
	})
	if len(fields) > 0 {
		event.Contexts["log"] = fields
	}
	if cause != nil {
		event.SetException(cause, 5)
		// Заголовок события - сообщение записи: «documents list failed» говорит больше, чем
		// тип ошибки pgx, а тип и текст ошибки остаются ниже, в исключении.
		event.Exception[len(event.Exception)-1].Value = r.Message + ": " + cause.Error()
	} else {
		event.SetException(errors.New(r.Message), 5)
	}

	if h.user != nil {
		if id, role, ok := h.user(ctx); ok {
			event.User = sentry.User{ID: id}
			event.Tags["role"] = role
		}
	}
	hubFrom(ctx).CaptureEvent(event)
}

// prefixed добавляет префикс группы к именам атрибутов.
func prefixed(prefix string, attrs []slog.Attr) []slog.Attr {
	if prefix == "" {
		return attrs
	}
	out := make([]slog.Attr, len(attrs))
	for i, a := range attrs {
		out[i] = slog.Attr{Key: prefix + a.Key, Value: a.Value}
	}
	return out
}
