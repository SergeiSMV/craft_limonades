package middleware

import (
	"context"
	"net/http"
	"strings"

	"craftwms/internal/auth"
	"craftwms/internal/model"
)

// ctxKey - приватный тип ключей контекста (чтобы не было коллизий с чужими значениями).
type ctxKey int

const (
	userIDKey ctxKey = iota
	roleKey
	accessKey
)

// Authenticator - «вахтёр» защищённых роутов.
//
// Что: проверяет access-токен из заголовка Authorization: Bearer <token>.
// Зачем: без валидного токена запрос дальше не идёт (401); заодно кладёт user_id и роль
// в контекст - оттуда их берут обработчики и (позже) audit_log.
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

// RightsSource - откуда middleware берёт доступ пользователя (ADHOC-49): действующие права,
// системная ли должность, активен ли. Реализует репозиторий пользователей.
type RightsSource interface {
	UserAccess(ctx context.Context, userID string) (model.Access, error)
}

// RequireAccess пропускает запрос, если доступ пользователя проходит правило [allow].
//
// Что: 401 - пользователь заблокирован или удалён; 403 - правило не прошло.
// Зачем: проверка по действиям должности (ADHOC-49/50), а не по роли.
// Как: доступ читается из базы на каждый запрос - смена должности и блокировка действуют
// сразу, а не после нового access-токена. Прочитанный доступ кладётся в контекст: обработчик
// документов и очередь операций уточняют право по виду документа и операции (AccessFromContext).
// Ставится после Authenticator.
func RequireAccess(src RightsSource, allow func(model.Access) bool) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			userID, _ := UserIDFromContext(r.Context())
			access, err := src.UserAccess(r.Context(), userID)
			if err != nil {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusInternalServerError)
				_, _ = w.Write([]byte(`{"error":"internal error"}`))
				return
			}
			if !access.Active {
				writeUnauthorized(w)
				return
			}
			if !allow(access) {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusForbidden)
				_, _ = w.Write([]byte(`{"error":"forbidden"}`))
				return
			}
			next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), accessKey, access)))
		})
	}
}

// AccessFromContext - доступ, прочитанный RequireAccess; ok=false - маршрут без проверки прав.
func AccessFromContext(ctx context.Context) (model.Access, bool) {
	a, ok := ctx.Value(accessKey).(model.Access)
	return a, ok
}

// UserIDFromContext достаёт id пользователя, положенный Authenticator.
func UserIDFromContext(ctx context.Context) (string, bool) {
	id, ok := ctx.Value(userIDKey).(string)
	return id, ok
}

// RoleFromContext достаёт роль пользователя из токена ("" - если её нет). С ADHOC-49 роль
// выводится из прав должности на момент выпуска токена и служит только меткой (Bugsink);
// доступ проверяет RequireAccess.
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
