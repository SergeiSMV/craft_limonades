package handler

import (
	"bytes"
	"compress/gzip"
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"

	"craftwms/internal/observability"
)

// ClientErrorsProject - проект в DSN, который строят приложения (`https://wms@<хост>/1`):
// приём конвертов - `POST /api/1/envelope/`. Настоящий проект Bugsink знает только сервер.
const ClientErrorsProject = "1"

// Пределы конверта клиента: сжатого тела и распакованного. Событие со стеком - килобайты;
// больше - либо сбой SDK, либо злоупотребление.
const (
	maxClientEnvelope         = 1 << 20
	maxClientEnvelopeUnpacked = 4 << 20
	maxRelayResponse          = 64 << 10
)

// EnvelopeRelay - пересылка конверта клиента в Bugsink (observability.Relay).
type EnvelopeRelay interface {
	Forward(ctx context.Context, envelope []byte) (*http.Response, error)
}

// ClientErrorsHandler принимает события ТСД и портала по протоколу Sentry и пересылает их в
// Bugsink (ADHOC-47). Без пересылки (стенд, локальный стек) конверт молча отбрасывается.
type ClientErrorsHandler struct {
	relay EnvelopeRelay
}

// NewClientErrorsHandler - relay nil: события отбрасываются.
func NewClientErrorsHandler(relay EnvelopeRelay) *ClientErrorsHandler {
	return &ClientErrorsHandler{relay: relay}
}

// Envelope: POST /api/{project}/envelope/ - конверт событий приложения.
//
// Входа не требует: падение до входа тоже надо увидеть. Ответ Bugsink - код, Retry-After и
// X-Sentry-Rate-Limits - возвращается как есть: SDK сам выдерживает паузу. Bugsink недоступен -
// 503 с паузой; ошибка пишется предупреждением, а не error: иначе отказ Bugsink порождал бы
// события бэкенда, которые тоже не дошли бы.
func (h *ClientErrorsHandler) Envelope(w http.ResponseWriter, r *http.Request) {
	if chi.URLParam(r, "project") != ClientErrorsProject {
		writeError(w, http.StatusNotFound, "неизвестный проект")
		return
	}
	envelope, status := readClientEnvelope(w, r)
	if status != 0 {
		writeError(w, status, http.StatusText(status))
		return
	}
	if h.relay == nil {
		writeJSON(w, http.StatusOK, map[string]string{})
		return
	}
	resp, err := h.relay.Forward(r.Context(), envelope)
	if errors.Is(err, observability.ErrBadEnvelope) {
		writeError(w, http.StatusBadRequest, "это не конверт Sentry")
		return
	}
	if err != nil {
		slog.WarnContext(r.Context(), "client error relay failed", "error", err)
		w.Header().Set("Retry-After", "60")
		writeError(w, http.StatusServiceUnavailable, "сбор ошибок недоступен")
		return
	}
	defer func() { _ = resp.Body.Close() }()
	for _, k := range []string{"Content-Type", "Retry-After", "X-Sentry-Rate-Limits"} {
		if v := resp.Header.Get(k); v != "" {
			w.Header().Set(k, v)
		}
	}
	w.WriteHeader(resp.StatusCode)
	_, _ = io.Copy(w, io.LimitReader(resp.Body, maxRelayResponse))
}

// readClientEnvelope читает тело конверта с пределами, снимая gzip (так шлёт нативный SDK
// Android). Второе значение - код отказа; 0 - тело прочитано.
func readClientEnvelope(w http.ResponseWriter, r *http.Request) ([]byte, int) {
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxClientEnvelope))
	if err != nil {
		return nil, http.StatusRequestEntityTooLarge
	}
	if !strings.EqualFold(r.Header.Get("Content-Encoding"), "gzip") {
		return raw, 0
	}
	zr, err := gzip.NewReader(bytes.NewReader(raw))
	if err != nil {
		return nil, http.StatusBadRequest
	}
	defer func() { _ = zr.Close() }()
	unpacked, err := io.ReadAll(io.LimitReader(zr, maxClientEnvelopeUnpacked+1))
	if err != nil {
		return nil, http.StatusBadRequest
	}
	if len(unpacked) > maxClientEnvelopeUnpacked {
		return nil, http.StatusRequestEntityTooLarge
	}
	return unpacked, 0
}
