package handler

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"

	appmw "craftwms/internal/middleware"
	"craftwms/internal/model"
)

// userAdmin - то, что обработчику нужно от сервиса пользователей и должностей.
type userAdmin interface {
	Rights() []string
	Positions(ctx context.Context) ([]model.Position, error)
	CreatePosition(ctx context.Context, in model.PositionInput, by string) (string, error)
	UpdatePosition(ctx context.Context, id string, in model.PositionInput, by string) error
	DeletePosition(ctx context.Context, id, by string) error
	Users(ctx context.Context) ([]model.UserListItem, error)
	CreateUser(ctx context.Context, in model.UserCreateInput) (string, error)
	UpdateUser(ctx context.Context, in model.UserUpdateInput) error
}

// UserAdminHandler - пользователи и должности в портале (ADHOC-49); право «пользователи и
// должности». Хеши, бейджи и пароли в ответы не попадают: у бейджа виден только логин
// (первые 8 цифр) - по нему офис узнаёт, какой бейдж выдан.
type UserAdminHandler struct {
	svc userAdmin
}

// NewUserAdminHandler создаёт обработчик пользователей и должностей.
func NewUserAdminHandler(svc userAdmin) *UserAdminHandler {
	return &UserAdminHandler{svc: svc}
}

type positionResponse struct {
	ID       string   `json:"id"`
	Name     string   `json:"name"`
	Rights   []string `json:"rights"`
	IsSystem bool     `json:"is_system"`
	Users    int      `json:"users"`
}

type positionRequest struct {
	Name   string   `json:"name"`
	Rights []string `json:"rights"`
}

type userResponse struct {
	ID           string `json:"id"`
	FullName     string `json:"full_name"`
	PositionID   string `json:"position_id"`
	PositionName string `json:"position_name"`
	Login        string `json:"login,omitempty"`    // бейдж: первые 8 цифр
	Username     string `json:"username,omitempty"` // вход по паролю
	IsActive     bool   `json:"is_active"`
	CreatedAt    string `json:"created_at"` // RFC3339
}

// Rights: GET /api/v1/rights - коды всех прав в порядке показа.
func (h *UserAdminHandler) Rights(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string][]string{"rights": h.svc.Rights()})
}

// Positions: GET /api/v1/positions - должности, системная первой.
func (h *UserAdminHandler) Positions(w http.ResponseWriter, r *http.Request) {
	items, err := h.svc.Positions(r.Context())
	if err != nil {
		userAdminError(w, r, err, "positions")
		return
	}
	out := make([]positionResponse, 0, len(items))
	for _, p := range items {
		out = append(out, positionResponse{ID: p.ID, Name: p.Name, Rights: p.Rights, IsSystem: p.IsSystem, Users: p.Users})
	}
	writeJSON(w, http.StatusOK, out)
}

// CreatePosition: POST /api/v1/positions {name, rights} - 201 {id} / 400 / 409.
func (h *UserAdminHandler) CreatePosition(w http.ResponseWriter, r *http.Request) {
	var req positionRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "тело запроса не JSON")
		return
	}
	id, err := h.svc.CreatePosition(r.Context(), model.PositionInput(req), currentUser(r))
	if err != nil {
		userAdminError(w, r, err, "create position")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
}

// UpdatePosition: PATCH /api/v1/positions/{id} {name, rights} - 204 / 400 / 404 / 409.
func (h *UserAdminHandler) UpdatePosition(w http.ResponseWriter, r *http.Request) {
	var req positionRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "тело запроса не JSON")
		return
	}
	if err := h.svc.UpdatePosition(r.Context(), chi.URLParam(r, "id"), model.PositionInput(req), currentUser(r)); err != nil {
		userAdminError(w, r, err, "update position")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// DeletePosition: DELETE /api/v1/positions/{id} - 204 / 404 / 409.
func (h *UserAdminHandler) DeletePosition(w http.ResponseWriter, r *http.Request) {
	if err := h.svc.DeletePosition(r.Context(), chi.URLParam(r, "id"), currentUser(r)); err != nil {
		userAdminError(w, r, err, "delete position")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// Users: GET /api/v1/users - все пользователи, активные сверху.
func (h *UserAdminHandler) Users(w http.ResponseWriter, r *http.Request) {
	items, err := h.svc.Users(r.Context())
	if err != nil {
		userAdminError(w, r, err, "users")
		return
	}
	out := make([]userResponse, 0, len(items))
	for _, u := range items {
		out = append(out, userResponse{
			ID: u.ID, FullName: u.FullName, PositionID: u.PositionID, PositionName: u.PositionName,
			Login: u.Login, Username: u.Username, IsActive: u.IsActive, CreatedAt: u.CreatedAt.Format(time.RFC3339),
		})
	}
	writeJSON(w, http.StatusOK, out)
}

// CreateUser: POST /api/v1/users {full_name, position_id, badge | username + password} -
// 201 {id} / 400 / 404 / 409.
func (h *UserAdminHandler) CreateUser(w http.ResponseWriter, r *http.Request) {
	var req struct {
		FullName   string `json:"full_name"`
		PositionID string `json:"position_id"`
		Badge      string `json:"badge"`
		Username   string `json:"username"`
		Password   string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "тело запроса не JSON")
		return
	}
	id, err := h.svc.CreateUser(r.Context(), model.UserCreateInput{
		FullName: req.FullName, PositionID: req.PositionID, Badge: req.Badge, Username: req.Username,
		Password: req.Password, By: currentUser(r),
	})
	if err != nil {
		userAdminError(w, r, err, "create user")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
}

// UpdateUser: PATCH /api/v1/users/{id} {full_name?, position_id?, is_active?, badge? | password?}
// - 204 / 400 / 404 / 409. Отсутствующее поле не меняется.
func (h *UserAdminHandler) UpdateUser(w http.ResponseWriter, r *http.Request) {
	var req struct {
		FullName   *string `json:"full_name"`
		PositionID *string `json:"position_id"`
		IsActive   *bool   `json:"is_active"`
		Badge      *string `json:"badge"`
		Password   *string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "тело запроса не JSON")
		return
	}
	if err := h.svc.UpdateUser(r.Context(), model.UserUpdateInput{
		ID: chi.URLParam(r, "id"), FullName: req.FullName, PositionID: req.PositionID, IsActive: req.IsActive,
		Badge: req.Badge, Password: req.Password, By: currentUser(r),
	}); err != nil {
		userAdminError(w, r, err, "update user")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func currentUser(r *http.Request) string {
	id, _ := appmw.UserIDFromContext(r.Context())
	return id
}

// userAdminError - ответ на ошибку пользователей и должностей; текст - для экрана портала.
func userAdminError(w http.ResponseWriter, r *http.Request, err error, action string) {
	switch {
	case errors.Is(err, model.ErrInvalidPosition), errors.Is(err, model.ErrInvalidUser):
		writeError(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, model.ErrBadBadge):
		writeError(w, http.StatusBadRequest, "бейдж - ровно 16 цифр")
	case errors.Is(err, model.ErrPositionNotFound), errors.Is(err, model.ErrUserMissing):
		writeError(w, http.StatusNotFound, err.Error())
	case errors.Is(err, model.ErrPositionSystem), errors.Is(err, model.ErrPositionNameTaken),
		errors.Is(err, model.ErrPositionInUse), errors.Is(err, model.ErrBadgeTaken),
		errors.Is(err, model.ErrUsernameTaken), errors.Is(err, model.ErrLastAdmin),
		errors.Is(err, model.ErrSelfBlock):
		writeError(w, http.StatusConflict, err.Error())
	default:
		slog.ErrorContext(r.Context(), "user admin failed", "action", action, "error", err)
		writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
	}
}
