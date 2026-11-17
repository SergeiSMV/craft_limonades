package handler

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"

	"github.com/go-chi/chi/v5"

	"craftwms/internal/model"
)

// problemReasonService - то, что обработчику нужно от справочника причин (ADHOC-55).
type problemReasonService interface {
	Reasons(ctx context.Context) ([]model.ProblemReason, error)
	Resolutions(ctx context.Context) ([]model.ProblemResolution, error)
	SaveReason(ctx context.Context, in model.ProblemReasonInput) (string, error)
	SaveResolution(ctx context.Context, in model.ProblemResolutionInput) (string, error)
}

// ProblemReasonHandler - справочник причин проблем и вариантов решения (ADHOC-55). Читает любой
// сотрудник (ТСД выбирает причину при пометке и подписывает ею проблемы), ведёт - право
// «Настройки: причины проблем» из портала.
type ProblemReasonHandler struct {
	svc problemReasonService
}

// NewProblemReasonHandler создаёт обработчик справочника причин.
func NewProblemReasonHandler(svc problemReasonService) *ProblemReasonHandler {
	return &ProblemReasonHandler{svc: svc}
}

type problemReasonResponse struct {
	Code            string `json:"code"`
	Name            string `json:"name"`
	IsSystem        bool   `json:"is_system"`
	Manual          bool   `json:"manual"` // кладовщик выбирает её на ТСД
	CommentRequired bool   `json:"comment_required"`
	IsActive        bool   `json:"is_active"`
	// Resolutions - id допустимых вариантов, и неактивных, в порядке справочника вариантов.
	Resolutions []string `json:"resolutions"`
}

type problemResolutionResponse struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Action   string `json:"action"`
	IsActive bool   `json:"is_active"`
}

// List: GET /api/v1/problem-reasons - {reasons, resolutions}: весь справочник, и неактивное.
func (h *ProblemReasonHandler) List(w http.ResponseWriter, r *http.Request) {
	reasons, err := h.svc.Reasons(r.Context())
	if err != nil {
		problemReasonError(w, r, err)
		return
	}
	resolutions, err := h.svc.Resolutions(r.Context())
	if err != nil {
		problemReasonError(w, r, err)
		return
	}
	out := struct {
		Reasons     []problemReasonResponse     `json:"reasons"`
		Resolutions []problemResolutionResponse `json:"resolutions"`
	}{Reasons: []problemReasonResponse{}, Resolutions: []problemResolutionResponse{}}
	for _, p := range reasons {
		out.Reasons = append(out.Reasons, problemReasonResponse{
			Code: p.Code, Name: p.Name, IsSystem: p.IsSystem, Manual: p.Manual,
			CommentRequired: p.CommentRequired, IsActive: p.IsActive, Resolutions: orEmpty(p.Resolutions),
		})
	}
	for _, x := range resolutions {
		out.Resolutions = append(out.Resolutions, problemResolutionResponse(x))
	}
	writeJSON(w, http.StatusOK, out)
}

// problemReasonRequest - правка причины; отсутствующее поле не меняется.
type problemReasonRequest struct {
	Name            *string   `json:"name"`
	CommentRequired *bool     `json:"comment_required"`
	IsActive        *bool     `json:"is_active"`
	Resolutions     *[]string `json:"resolutions"`
}

// CreateReason: POST /api/v1/problem-reasons {name, comment_required?, resolutions} -
// 201 {code} / 400 / 409.
func (h *ProblemReasonHandler) CreateReason(w http.ResponseWriter, r *http.Request) {
	h.saveReason(w, r, "")
}

// UpdateReason: PATCH /api/v1/problem-reasons/{code} {name?, comment_required?, is_active?,
// resolutions?} - 200 {code} / 400 / 404 / 409.
func (h *ProblemReasonHandler) UpdateReason(w http.ResponseWriter, r *http.Request) {
	h.saveReason(w, r, chi.URLParam(r, "code"))
}

func (h *ProblemReasonHandler) saveReason(w http.ResponseWriter, r *http.Request, code string) {
	var req problemReasonRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "тело запроса не JSON")
		return
	}
	saved, err := h.svc.SaveReason(r.Context(), model.ProblemReasonInput{
		Code: code, Name: req.Name, CommentRequired: req.CommentRequired, IsActive: req.IsActive,
		Resolutions: req.Resolutions, By: currentUser(r),
	})
	if err != nil {
		problemReasonError(w, r, err)
		return
	}
	status := http.StatusOK
	if code == "" {
		status = http.StatusCreated
	}
	writeJSON(w, status, map[string]string{"code": saved})
}

// problemResolutionRequest - правка варианта; отсутствующее поле не меняется.
type problemResolutionRequest struct {
	Name     *string `json:"name"`
	Action   string  `json:"action"`
	IsActive *bool   `json:"is_active"`
}

// CreateResolution: POST /api/v1/problem-resolutions {name, action} - 201 {id} / 400 / 409.
func (h *ProblemReasonHandler) CreateResolution(w http.ResponseWriter, r *http.Request) {
	h.saveResolution(w, r, "")
}

// UpdateResolution: PATCH /api/v1/problem-resolutions/{id} {name?, is_active?} - 200 {id} /
// 400 / 404 / 409. Действие варианта не меняется.
func (h *ProblemReasonHandler) UpdateResolution(w http.ResponseWriter, r *http.Request) {
	h.saveResolution(w, r, chi.URLParam(r, "id"))
}

func (h *ProblemReasonHandler) saveResolution(w http.ResponseWriter, r *http.Request, id string) {
	var req problemResolutionRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "тело запроса не JSON")
		return
	}
	saved, err := h.svc.SaveResolution(r.Context(), model.ProblemResolutionInput{
		ID: id, Name: req.Name, Action: req.Action, IsActive: req.IsActive, By: currentUser(r),
	})
	if err != nil {
		problemReasonError(w, r, err)
		return
	}
	status := http.StatusOK
	if id == "" {
		status = http.StatusCreated
	}
	writeJSON(w, status, map[string]string{"id": saved})
}

// problemReasonError - ответ на ошибку справочника причин; текст - для экрана портала.
func problemReasonError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, model.ErrInvalidProblemReason), errors.Is(err, model.ErrInvalidResolution):
		writeError(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, model.ErrProblemReasonNotFound), errors.Is(err, model.ErrResolutionNotFound):
		writeError(w, http.StatusNotFound, err.Error())
	case errors.Is(err, model.ErrProblemReasonSystem), errors.Is(err, model.ErrProblemReasonNameTaken),
		errors.Is(err, model.ErrResolutionNameTaken), errors.Is(err, model.ErrResolutionRegradeMismatch):
		writeError(w, http.StatusConflict, err.Error())
	default:
		slog.ErrorContext(r.Context(), "problem reasons failed", "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
	}
}
