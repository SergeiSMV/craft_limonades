package handler

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"

	"github.com/go-chi/chi/v5"

	appmw "craftwms/internal/middleware"
	"craftwms/internal/model"
)

// problemPhotos — что обработчику нужно от сервиса фото проблем (ADHOC-45).
type problemPhotos interface {
	Save(ctx context.Context, in model.ProblemPhotoInput) error
	Get(ctx context.Context, problemID, photoID string) (model.ProblemPhoto, error)
}

// ProblemPhotoHandler — фото к проблемам склада: загрузка с ТСД и отдача ТСД и порталу.
type ProblemPhotoHandler struct {
	svc problemPhotos
}

// NewProblemPhotoHandler создаёт обработчик фото проблем.
func NewProblemPhotoHandler(svc problemPhotos) *ProblemPhotoHandler {
	return &ProblemPhotoHandler{svc: svc}
}

// Put: PUT /api/v1/problems/{id}/photos/{photoId} — тело — сам снимок (JPEG, PNG, WebP).
//
// PUT, а не POST: идентификатор фото выдаёт ТСД, и повтор загрузки из очереди — та же запись,
// а не вторая. 204 — снимок на сервере (в том числе после повтора).
func (h *ProblemPhotoHandler) Put(w http.ResponseWriter, r *http.Request) {
	// +1 байт сверх предела: так переполнение отличимо от снимка ровно предельного размера.
	body, err := io.ReadAll(io.LimitReader(r.Body, model.ProblemPhotoMaxBytes+1))
	if err != nil {
		writeError(w, http.StatusBadRequest, "не удалось прочитать снимок")
		return
	}
	userID, _ := appmw.UserIDFromContext(r.Context())
	err = h.svc.Save(r.Context(), model.ProblemPhotoInput{
		ID: chi.URLParam(r, "photoId"), ProblemID: chi.URLParam(r, "id"),
		Content: body, CreatedBy: userID,
	})
	if err != nil {
		problemPhotoError(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// Get: GET /api/v1/problems/{id}/photos/{photoId} — снимок как есть.
//
// Снимок не меняется никогда (идентификатор — новый на каждый снимок), поэтому кэшируется
// надолго; `private` — он за входом и в общих кэшах лежать не должен.
func (h *ProblemPhotoHandler) Get(w http.ResponseWriter, r *http.Request) {
	p, err := h.svc.Get(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "photoId"))
	if err != nil {
		problemPhotoError(w, r, err)
		return
	}
	w.Header().Set("Content-Type", p.ContentType)
	w.Header().Set("Cache-Control", "private, max-age=31536000, immutable")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(p.Content)
}

// problemPhotoError — ответ на ошибку фото; текст — для экрана ТСД и журнала очереди.
func problemPhotoError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, model.ErrPhotoProblemNotFound):
		writeError(w, http.StatusNotFound, "проблема не найдена")
	case errors.Is(err, model.ErrPhotoNotFound):
		writeError(w, http.StatusNotFound, "фото не найдено")
	case errors.Is(err, model.ErrPhotoProblemResolved):
		writeError(w, http.StatusConflict, "по проблеме уже принято решение — фото не добавить")
	case errors.Is(err, model.ErrPhotoLimit):
		writeError(w, http.StatusConflict, "у проблемы уже три фото")
	case errors.Is(err, model.ErrPhotoIDTaken):
		writeError(w, http.StatusConflict, "идентификатор фото занят другой проблемой")
	case errors.Is(err, model.ErrPhotoTooLarge):
		writeError(w, http.StatusRequestEntityTooLarge, "снимок больше 1 МБ")
	case errors.Is(err, model.ErrPhotoInvalid):
		writeError(w, http.StatusBadRequest, "это не снимок JPEG, PNG или WebP")
	default:
		slog.ErrorContext(r.Context(), "problem photo failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
	}
}
