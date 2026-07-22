// Package service — бизнес-логика (use-cases). Оркеструет репозитории и примитивы auth.
package service

import (
	"context"
	"errors"

	"craftwms/internal/auth"
	"craftwms/internal/model"
)

// Ошибки сервиса. Для входа отдаём один общий ErrInvalidCredentials (не различаем «нет логина»
// и «неверный секрет»), чтобы не подсказывать перебору, какие логины существуют.
var (
	ErrBadBadge           = errors.New("badge must be 16 digits")
	ErrInvalidCredentials = errors.New("invalid credentials")
)

// userRepo — то, что нужно AuthService от хранилища (зависимость от интерфейса, а не реализации).
type userRepo interface {
	GetByLogin(ctx context.Context, login string) (model.User, error)
	GetByUsername(ctx context.Context, username string) (model.User, error)
	GetByID(ctx context.Context, id string) (model.User, error)
}

// AuthService — аутентификация по бейджу и выдача/обновление токенов.
type AuthService struct {
	users  userRepo
	tokens *auth.TokenManager
}

// NewAuthService собирает сервис из репозитория пользователей и менеджера токенов.
func NewAuthService(users userRepo, tokens *auth.TokenManager) *AuthService {
	return &AuthService{users: users, tokens: tokens}
}

// TokenPair — пара токенов, выдаётся при успешном входе.
type TokenPair struct {
	Access  string
	Refresh string
}

// Login: бейдж (16 цифр) → режем на логин(8)/секрет(8) → ищем юзера → сверяем argon2 →
// проверяем активность → выдаём пару токенов.
func (s *AuthService) Login(ctx context.Context, badge string) (TokenPair, error) {
	if !isBadge(badge) {
		return TokenPair{}, ErrBadBadge
	}
	login, secret := badge[:8], badge[8:]

	user, err := s.users.GetByLogin(ctx, login)
	if err != nil {
		return TokenPair{}, ErrInvalidCredentials // в т.ч. «не найден» — без деталей
	}
	if !user.IsActive {
		return TokenPair{}, ErrInvalidCredentials // заблокирован
	}
	ok, err := auth.VerifyPassword(secret, user.PasswordHash)
	if err != nil || !ok {
		return TokenPair{}, ErrInvalidCredentials
	}
	return s.issuePair(user)
}

// LoginWithPassword: вход admin/менеджера по username+паролю (смартфон/web, не бейдж) — P1-01-1.
// Ищем по username → сверяем argon2 → проверяем активность → та же пара токенов, что и по бейджу.
func (s *AuthService) LoginWithPassword(ctx context.Context, username, password string) (TokenPair, error) {
	if username == "" || password == "" {
		return TokenPair{}, ErrInvalidCredentials
	}
	user, err := s.users.GetByUsername(ctx, username)
	if err != nil {
		return TokenPair{}, ErrInvalidCredentials // в т.ч. «не найден» — без деталей
	}
	if !user.IsActive {
		return TokenPair{}, ErrInvalidCredentials // заблокирован
	}
	ok, err := auth.VerifyPassword(password, user.PasswordHash)
	if err != nil || !ok {
		return TokenPair{}, ErrInvalidCredentials
	}
	return s.issuePair(user)
}

// Refresh: валидный refresh-токен → перечитываем пользователя из БД (is_active/role могли
// измениться) → выдаём свежий access. Так блокировка и смена роли подхватываются на refresh.
func (s *AuthService) Refresh(ctx context.Context, refreshToken string) (string, error) {
	claims, err := s.tokens.ParseRefresh(refreshToken)
	if err != nil {
		return "", ErrInvalidCredentials
	}
	user, err := s.users.GetByID(ctx, claims.Subject)
	if err != nil || !user.IsActive {
		return "", ErrInvalidCredentials
	}
	return s.tokens.IssueAccess(user.ID, user.Role)
}

// Profile возвращает пользователя по id (для защищённого /auth/me).
func (s *AuthService) Profile(ctx context.Context, userID string) (model.User, error) {
	return s.users.GetByID(ctx, userID)
}

// issuePair выпускает access+refresh для пользователя.
func (s *AuthService) issuePair(user model.User) (TokenPair, error) {
	access, err := s.tokens.IssueAccess(user.ID, user.Role)
	if err != nil {
		return TokenPair{}, err
	}
	refresh, err := s.tokens.IssueRefresh(user.ID)
	if err != nil {
		return TokenPair{}, err
	}
	return TokenPair{Access: access, Refresh: refresh}, nil
}

// isBadge проверяет, что строка — ровно 16 десятичных цифр.
func isBadge(s string) bool {
	if len(s) != 16 {
		return false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}
