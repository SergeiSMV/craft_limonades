package handler

import (
	"encoding/json"
	"errors"
	"net/http"

	"craftwms/internal/middleware"
	"craftwms/internal/service"
)

// AuthHandler — HTTP-обработчики аутентификации.
type AuthHandler struct {
	svc *service.AuthService
}

// NewAuthHandler создаёт обработчик аутентификации.
func NewAuthHandler(svc *service.AuthService) *AuthHandler {
	return &AuthHandler{svc: svc}
}

type loginRequest struct {
	Badge string `json:"badge"` // 16 цифр отсканированного бейджа
}

type tokenPairResponse struct {
	Access  string `json:"access"`
	Refresh string `json:"refresh"`
}

// Login: POST /api/v1/auth/login {"badge":"<16 цифр>"} → пара токенов.
func (h *AuthHandler) Login(w http.ResponseWriter, r *http.Request) {
	var req loginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json")
		return
	}
	pair, err := h.svc.Login(r.Context(), req.Badge)
	switch {
	case errors.Is(err, service.ErrBadBadge):
		writeError(w, http.StatusBadRequest, "badge must be 16 digits")
		return
	case err != nil:
		// Общий 401 без деталей — не подсказываем, логин или секрет неверен.
		writeError(w, http.StatusUnauthorized, "invalid credentials")
		return
	}
	writeJSON(w, http.StatusOK, tokenPairResponse{Access: pair.Access, Refresh: pair.Refresh})
}

type loginPasswordRequest struct {
	Username string `json:"username"` // логин admin/менеджера (не бейдж)
	Password string `json:"password"`
}

// LoginPassword: POST /api/v1/auth/login/password {"username","password"} → пара токенов.
// Путь для admin/менеджера (смартфон/web); работник входит по бейджу через /api/v1/auth/login.
func (h *AuthHandler) LoginPassword(w http.ResponseWriter, r *http.Request) {
	var req loginPasswordRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json")
		return
	}
	pair, err := h.svc.LoginWithPassword(r.Context(), req.Username, req.Password)
	if err != nil {
		// Общий 401 без деталей — не подсказываем, логин или пароль неверен.
		writeError(w, http.StatusUnauthorized, "invalid credentials")
		return
	}
	writeJSON(w, http.StatusOK, tokenPairResponse{Access: pair.Access, Refresh: pair.Refresh})
}

type refreshRequest struct {
	Refresh string `json:"refresh"`
}

type accessResponse struct {
	Access string `json:"access"`
}

// Refresh: POST /api/v1/auth/refresh {"refresh":"<jwt>"} → новый access.
func (h *AuthHandler) Refresh(w http.ResponseWriter, r *http.Request) {
	var req refreshRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json")
		return
	}
	access, err := h.svc.Refresh(r.Context(), req.Refresh)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "invalid refresh token")
		return
	}
	writeJSON(w, http.StatusOK, accessResponse{Access: access})
}

type meResponse struct {
	UserID   string `json:"user_id"`
	Login    string `json:"login"`
	FullName string `json:"full_name"`
	Role     string `json:"role"`
}

// Me: GET /api/v1/auth/me (защищённый) → профиль текущего пользователя.
// Демонстрирует, что middleware положил user_id в контекст, а роут его знает.
func (h *AuthHandler) Me(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.UserIDFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	user, err := h.svc.Profile(r.Context(), userID)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	writeJSON(w, http.StatusOK, meResponse{
		UserID:   user.ID,
		Login:    user.Login,
		FullName: user.FullName,
		Role:     user.Role,
	})
}

// writeError — единый JSON-ответ об ошибке.
func writeError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}
