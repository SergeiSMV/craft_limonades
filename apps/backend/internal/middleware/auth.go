package middleware

import (
	"context"
	"net/http"
	"strings"

	"craftwms/internal/auth"
)

// ctxKey — приватный тип ключей контекста (чтобы не было коллизий с чужими значениями).
type ctxKey int

const (
	userIDKey ctxKey = iota
	roleKey
)

// Authenticator — «вахтёр» защищённых роутов.
//
// Что: проверяет access-токен из заголовка Authorization: Bearer <token>.
// Зачем: без валидного токена запрос дальше не идёт (401); заодно кладёт user_id и роль
// в контекст — оттуда их берут обработчики и (позже) audit_log.
// Как: парсит Bearer, проверяет подпись/срок токена, обогащает контекст.
func Authenticator(tokens *auth.TokenManager) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			token, ok := bearerToken(r)
			if !ok {
				writeUnauthorized(w)
				return
			}
			claims, err := tokens.ParseAccess(token)
			if err != nil {
				writeUnauthorized(w)
				return
			}
			ctx := context.WithValue(r.Context(), userIDKey, claims.Subject)
			ctx = context.WithValue(ctx, roleKey, claims.Role)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// RequireRole пропускает только пользователей с нужной ролью (для admin-only ручек). Иначе 403.
func RequireRole(role string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if RoleFromContext(r.Context()) != role {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusForbidden)
				_, _ = w.Write([]byte(`{"error":"forbidden"}`))
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// UserIDFromContext достаёт id пользователя, положенный Authenticator.
func UserIDFromContext(ctx context.Context) (string, bool) {
	id, ok := ctx.Value(userIDKey).(string)
	return id, ok
}

// RoleFromContext достаёт роль пользователя из контекста ("" — если её нет).
func RoleFromContext(ctx context.Context) string {
	role, _ := ctx.Value(roleKey).(string)
	return role
}

// bearerToken извлекает токен из заголовка "Authorization: Bearer <token>".
func bearerToken(r *http.Request) (string, bool) {
	h := r.Header.Get("Authorization")
	const prefix = "Bearer "
	if len(h) <= len(prefix) || !strings.EqualFold(h[:len(prefix)], prefix) {
		return "", false
	}
	return strings.TrimSpace(h[len(prefix):]), true
}

// writeUnauthorized отдаёт единый 401.
func writeUnauthorized(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusUnauthorized)
	_, _ = w.Write([]byte(`{"error":"unauthorized"}`))
}
