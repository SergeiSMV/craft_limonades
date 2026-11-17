package handler

import (
	"errors"
	"log/slog"
	"net/http"

	"github.com/go-chi/chi/v5"

	"craftwms/internal/model"
	"craftwms/internal/service"
)

// BadgeHandler - «Бейджи» на ТСД (ADHOC-65): кого пользователь вправе печатать и номер к печати.
// Онлайн: номер раскрывает только сервер, и каждое раскрытие пишется в журнал.
type BadgeHandler struct {
	svc *service.BadgeService
}

// NewBadgeHandler создаёт обработчик бейджей.
func NewBadgeHandler(svc *service.BadgeService) *BadgeHandler {
	return &BadgeHandler{svc: svc}
}

type badgeHolderResponse struct {
	ID           string `json:"id"`
	FullName     string `json:"full_name"`
	PositionName string `json:"position_name"`
	IsAdmin      bool   `json:"is_admin"`
	Stored       bool   `json:"stored"` // номер сохранён - можно печатать
}

type badgeResponse struct {
	UserID   string `json:"user_id"`
	FullName string `json:"full_name"`
	Badge    string `json:"badge"` // 16 цифр
}

// Holders: GET /api/v1/badges - сотрудники, чьи бейджи можно печатать, по ФИО.
func (h *BadgeHandler) Holders(w http.ResponseWriter, r *http.Request) {
	items, err := h.svc.Holders(r.Context(), currentUser(r))
	if err != nil {
		badgeError(w, r, err)
		return
	}
	out := make([]badgeHolderResponse, 0, len(items))
	for _, it := range items {
		out = append(out, badgeHolderResponse(it))
	}
	writeJSON(w, http.StatusOK, out)
}

// Badge: GET /api/v1/badges/{id} - номер бейджа к печати; 403 / 404 / 409 (не сохранён) / 503
// (ключ не задан).
func (h *BadgeHandler) Badge(w http.ResponseWriter, r *http.Request) {
	b, err := h.svc.Badge(r.Context(), currentUser(r), chi.URLParam(r, "id"))
	if err != nil {
		badgeError(w, r, err)
		return
	}
	// Номер - секрет входа: ни в кэш прокси, ни в кэш клиента.
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, badgeResponse{UserID: b.UserID, FullName: b.FullName, Badge: b.Number})
}

// badgeError - ответ на ошибку печати бейджей; текст - для экрана ТСД.
func badgeError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, model.ErrBadgeForbidden):
		writeError(w, http.StatusForbidden, err.Error())
	case errors.Is(err, model.ErrUserMissing):
		writeError(w, http.StatusNotFound, "сотрудник не найден, заблокирован или входит по паролю")
	case errors.Is(err, model.ErrBadgeNotStored):
		writeError(w, http.StatusConflict, err.Error())
	case errors.Is(err, model.ErrBadgeKeyMissing):
		writeError(w, http.StatusServiceUnavailable, err.Error())
	default:
		slog.ErrorContext(r.Context(), "badges failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
	}
}
