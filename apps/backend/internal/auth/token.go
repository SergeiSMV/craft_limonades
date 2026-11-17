package auth

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// Типы токенов - кладём в claim typ, чтобы refresh нельзя было использовать как access и наоборот.
const (
	typeAccess  = "access"
	typeRefresh = "refresh"
)

// ErrInvalidToken - токен не прошёл проверку (подпись/срок/тип).
var ErrInvalidToken = errors.New("invalid token")

// Claims - полезная нагрузка JWT: стандартные поля + роль и тип токена.
type Claims struct {
	Role string `json:"role,omitempty"`
	Typ  string `json:"typ"`
	jwt.RegisteredClaims
}

// TokenManager выпускает и проверяет JWT. Один экземпляр общий для service (выпуск) и middleware (проверка).
type TokenManager struct {
	secret     []byte
	accessTTL  time.Duration
	refreshTTL time.Duration
}

// NewTokenManager создаёт менеджер токенов с секретом подписи и временами жизни.
func NewTokenManager(secret string, accessTTL, refreshTTL time.Duration) *TokenManager {
	return &TokenManager{secret: []byte(secret), accessTTL: accessTTL, refreshTTL: refreshTTL}
}

// IssueAccess выпускает короткоживущий access-токен с ролью (её проверяет middleware, не ходя в БД).
func (m *TokenManager) IssueAccess(userID, role string) (string, error) {
	return m.sign(userID, role, typeAccess, m.accessTTL)
}

// IssueRefresh выпускает долгоживущий refresh-токен (роль в него не кладём - она перечитывается из БД на refresh).
func (m *TokenManager) IssueRefresh(userID string) (string, error) {
	return m.sign(userID, "", typeRefresh, m.refreshTTL)
}

// ParseAccess проверяет access-токен и возвращает claims.
func (m *TokenManager) ParseAccess(token string) (*Claims, error) {
	return m.parse(token, typeAccess)
}

// ParseRefresh проверяет refresh-токен и возвращает claims.
func (m *TokenManager) ParseRefresh(token string) (*Claims, error) {
	return m.parse(token, typeRefresh)
}

// sign собирает и подписывает токен HS256.
func (m *TokenManager) sign(userID, role, typ string, ttl time.Duration) (string, error) {
	now := time.Now()
	claims := Claims{
		Role: role,
		Typ:  typ,
		RegisteredClaims: jwt.RegisteredClaims{
			ID:        randID(), // jti - делает каждый токен уникальным даже в пределах секунды
			Subject:   userID,   // sub = id пользователя
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(ttl)),
		},
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(m.secret)
}

// randID возвращает случайный 128-битный идентификатор (hex) для jti токена.
func randID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// parse проверяет подпись, срок и тип токена.
func (m *TokenManager) parse(token, wantType string) (*Claims, error) {
	claims := &Claims{}
	_, err := jwt.ParseWithClaims(token, claims, func(t *jwt.Token) (any, error) {
		// Защита от подмены алгоритма: принимаем только HMAC.
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", t.Header["alg"])
		}
		return m.secret, nil
	})
	if err != nil {
		return nil, ErrInvalidToken
	}
	if claims.Typ != wantType {
		return nil, ErrInvalidToken
	}
	return claims, nil
}
