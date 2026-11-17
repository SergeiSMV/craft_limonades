package handler

import (
	"context"
	"errors"
	"net/http"

	"craftwms/internal/model"
	"craftwms/internal/service"
)

// DemoService - то, что ручкам демо-режима нужно от сервиса (ADHOC-67).
type DemoService interface {
	Status(ctx context.Context) model.DemoStatus
	Login(ctx context.Context) (service.TokenPair, error)
	Reset(ctx context.Context) error
}

// DemoHandler - ручки демо-режима: состояние, вход без пароля, сброс.
type DemoHandler struct {
	svc DemoService
}

// NewDemoHandler создаёт обработчик демо-режима.
func NewDemoHandler(svc DemoService) *DemoHandler {
	return &DemoHandler{svc: svc}
}

// Status: GET /api/v1/demo (публичный) → {"enabled":…}. По нему экран входа портала решает,
// показывать ли «Войти в демо». На боевом сервере - {"enabled":false}.
func (h *DemoHandler) Status(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, h.svc.Status(r.Context()))
}

// Login: POST /api/v1/auth/demo (публичный) → пара токенов демо-пользователя.
// Не демо-сервер - 404, как у несуществующей ручки; идёт сброс - 503.
func (h *DemoHandler) Login(w http.ResponseWriter, r *http.Request) {
	pair, err := h.svc.Login(r.Context())
	switch {
	case errors.Is(err, model.ErrDemoDisabled):
		writeError(w, http.StatusNotFound, "not found")
	case err != nil:
		writeError(w, http.StatusServiceUnavailable, "демо обновляется, попробуйте через минуту")
	default:
		writeJSON(w, http.StatusOK, tokenPairResponse{Access: pair.Access, Refresh: pair.Refresh})
	}
}

// Reset: POST /api/v1/demo/reset (только «Администратор») → 204. Стирает данные демо и
// заполняет заново; все, кто сейчас в демо, войдут снова.
func (h *DemoHandler) Reset(w http.ResponseWriter, r *http.Request) {
	// Без отмены по обрыву соединения: сброс, прерванный на середине, оставил бы пустую базу.
	err := h.svc.Reset(context.WithoutCancel(r.Context()))
	switch {
	case err == nil:
		w.WriteHeader(http.StatusNoContent)
	case errors.Is(err, model.ErrDemoDisabled):
		writeError(w, http.StatusNotFound, "not found")
	case errors.Is(err, model.ErrDemoResetTooOften), errors.Is(err, model.ErrDemoResetRunning):
		writeError(w, http.StatusTooManyRequests, err.Error())
	default:
		writeError(w, http.StatusInternalServerError, "сброс демо не удался")
	}
}
