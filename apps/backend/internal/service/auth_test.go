package service

import (
	"context"
	"errors"
	"testing"
	"time"

	"craftwms/internal/auth"
	"craftwms/internal/model"
)

// fakeUserRepo — in-memory реализация userRepo для тестов сервиса (без БД).
type fakeUserRepo struct {
	byLogin    map[string]model.User
	byUsername map[string]model.User
	byID       map[string]model.User
}

func newFakeRepo() *fakeUserRepo {
	return &fakeUserRepo{
		byLogin:    map[string]model.User{},
		byUsername: map[string]model.User{},
		byID:       map[string]model.User{},
	}
}

func (f *fakeUserRepo) add(u model.User) {
	if u.Login != "" {
		f.byLogin[u.Login] = u
	}
	if u.Username != "" {
		f.byUsername[u.Username] = u
	}
	f.byID[u.ID] = u
}

func (f *fakeUserRepo) GetByLogin(_ context.Context, login string) (model.User, error) {
	u, ok := f.byLogin[login]
	if !ok {
		return model.User{}, errors.New("not found")
	}
	return u, nil
}

func (f *fakeUserRepo) GetByUsername(_ context.Context, username string) (model.User, error) {
	u, ok := f.byUsername[username]
	if !ok {
		return model.User{}, errors.New("not found")
	}
	return u, nil
}

func (f *fakeUserRepo) GetByID(_ context.Context, id string) (model.User, error) {
	u, ok := f.byID[id]
	if !ok {
		return model.User{}, errors.New("not found")
	}
	return u, nil
}

// Тестовый бейдж: логин "10000000" + секрет "23456781".
const (
	testBadge  = "1000000023456781"
	testLogin  = "10000000"
	testSecret = "23456781"
	testUserID = "user-uuid-1"
)

// Тестовый admin с входом по логину/паролю (P1-01-1).
const (
	testUsername = "admin"
	testPassword = "supersecret123"
	testAdminID  = "admin-uuid-1"
)

// addUsernameAdmin добавляет в fake-репозиторий активного admin с username+паролем.
func addUsernameAdmin(t *testing.T, repo *fakeUserRepo) {
	t.Helper()
	hash, err := auth.HashPassword(testPassword)
	if err != nil {
		t.Fatalf("HashPassword: %v", err)
	}
	repo.add(model.User{
		ID:           testAdminID,
		Username:     testUsername,
		PasswordHash: hash,
		FullName:     "Админ Паролевич",
		Role:         model.RoleAdmin,
		IsActive:     true,
	})
}

// newService собирает сервис с fake-репозиторием и реальным менеджером токенов;
// при needUser добавляет активного admin с корректным argon2-хешем секрета.
func newService(t *testing.T, addUser bool) (*AuthService, *auth.TokenManager, *fakeUserRepo) {
	t.Helper()
	repo := newFakeRepo()
	tm := auth.NewTokenManager("svc-secret", time.Hour, 24*time.Hour)

	if addUser {
		hash, err := auth.HashPassword(testSecret)
		if err != nil {
			t.Fatalf("HashPassword: %v", err)
		}
		repo.add(model.User{
			ID:           testUserID,
			Login:        testLogin,
			PasswordHash: hash,
			FullName:     "Тест Тестович",
			Role:         model.RoleAdmin,
			IsActive:     true,
		})
	}
	return NewAuthService(repo, tm), tm, repo
}

// Успешный вход: валидный бейдж активного пользователя → пара токенов,
// access несёт sub=userID и роль.
func TestLoginSuccess(t *testing.T) {
	svc, tm, _ := newService(t, true)

	pair, err := svc.Login(context.Background(), testBadge)
	if err != nil {
		t.Fatalf("Login: %v", err)
	}
	if pair.Access == "" || pair.Refresh == "" {
		t.Fatal("ожидались непустые access и refresh")
	}

	claims, err := tm.ParseAccess(pair.Access)
	if err != nil {
		t.Fatalf("ParseAccess: %v", err)
	}
	if claims.Subject != testUserID {
		t.Errorf("sub = %q, want %q", claims.Subject, testUserID)
	}
	if claims.Role != model.RoleAdmin {
		t.Errorf("role = %q, want %q", claims.Role, model.RoleAdmin)
	}
	if _, err := tm.ParseRefresh(pair.Refresh); err != nil {
		t.Errorf("ParseRefresh: %v", err)
	}
}

// Невалидный бейдж (не 16 цифр / нецифры) → ErrBadBadge, в БД не ходим.
func TestLoginBadBadge(t *testing.T) {
	svc, _, _ := newService(t, true)

	cases := []string{
		"123",               // короткий
		"100000002345678",   // 15 цифр
		"10000000234567812", // 17 цифр
		"100000002345678a",  // нецифровой символ
		"",                  // пустой
	}
	for _, badge := range cases {
		if _, err := svc.Login(context.Background(), badge); !errors.Is(err, ErrBadBadge) {
			t.Errorf("Login(%q) err = %v, want ErrBadBadge", badge, err)
		}
	}
}

// Пользователь не найден → общий ErrInvalidCredentials (без деталей).
func TestLoginUserNotFound(t *testing.T) {
	svc, _, _ := newService(t, false) // пользователей нет

	if _, err := svc.Login(context.Background(), testBadge); !errors.Is(err, ErrInvalidCredentials) {
		t.Errorf("err = %v, want ErrInvalidCredentials", err)
	}
}

// Заблокированный пользователь (is_active=false) → ErrInvalidCredentials.
func TestLoginInactiveUser(t *testing.T) {
	svc, _, repo := newService(t, true)
	u := repo.byLogin[testLogin]
	u.IsActive = false
	repo.add(u)

	if _, err := svc.Login(context.Background(), testBadge); !errors.Is(err, ErrInvalidCredentials) {
		t.Errorf("err = %v, want ErrInvalidCredentials", err)
	}
}

// Неверный секрет (правильный логин, чужие последние 8 цифр) → ErrInvalidCredentials.
func TestLoginWrongSecret(t *testing.T) {
	svc, _, _ := newService(t, true)

	wrongBadge := testLogin + "00000000" // верный логин, неверный секрет
	if _, err := svc.Login(context.Background(), wrongBadge); !errors.Is(err, ErrInvalidCredentials) {
		t.Errorf("err = %v, want ErrInvalidCredentials", err)
	}
}

// Refresh валидного токена активного пользователя → свежий access с ролью.
func TestRefreshSuccess(t *testing.T) {
	svc, tm, _ := newService(t, true)

	refresh, err := tm.IssueRefresh(testUserID)
	if err != nil {
		t.Fatalf("IssueRefresh: %v", err)
	}

	access, err := svc.Refresh(context.Background(), refresh)
	if err != nil {
		t.Fatalf("Refresh: %v", err)
	}
	claims, err := tm.ParseAccess(access)
	if err != nil {
		t.Fatalf("ParseAccess: %v", err)
	}
	if claims.Subject != testUserID {
		t.Errorf("sub = %q, want %q", claims.Subject, testUserID)
	}
	if claims.Role != model.RoleAdmin {
		t.Errorf("role = %q, want %q", claims.Role, model.RoleAdmin)
	}
}

// Невалидный refresh-токен → ErrInvalidCredentials.
func TestRefreshInvalidToken(t *testing.T) {
	svc, _, _ := newService(t, true)

	if _, err := svc.Refresh(context.Background(), "garbage"); !errors.Is(err, ErrInvalidCredentials) {
		t.Errorf("err = %v, want ErrInvalidCredentials", err)
	}
}

// Refresh для заблокированного пользователя → ErrInvalidCredentials
// (блокировка подхватывается на refresh — перечитываем из БД).
func TestRefreshInactiveUser(t *testing.T) {
	svc, tm, repo := newService(t, true)

	refresh, _ := tm.IssueRefresh(testUserID)
	u := repo.byID[testUserID]
	u.IsActive = false
	repo.add(u)

	if _, err := svc.Refresh(context.Background(), refresh); !errors.Is(err, ErrInvalidCredentials) {
		t.Errorf("err = %v, want ErrInvalidCredentials", err)
	}
}

// Access-токен нельзя использовать как refresh (тип не тот) → ErrInvalidCredentials.
func TestRefreshRejectsAccessToken(t *testing.T) {
	svc, tm, _ := newService(t, true)

	access, _ := tm.IssueAccess(testUserID, model.RoleAdmin)
	if _, err := svc.Refresh(context.Background(), access); !errors.Is(err, ErrInvalidCredentials) {
		t.Errorf("err = %v, want ErrInvalidCredentials", err)
	}
}

// LoginWithPassword: успех — валидный username+пароль активного admin → пара токенов.
func TestLoginWithPasswordSuccess(t *testing.T) {
	svc, tm, repo := newService(t, false)
	addUsernameAdmin(t, repo)

	pair, err := svc.LoginWithPassword(context.Background(), testUsername, testPassword)
	if err != nil {
		t.Fatalf("LoginWithPassword: %v", err)
	}
	if pair.Access == "" || pair.Refresh == "" {
		t.Fatal("ожидались непустые access и refresh")
	}
	claims, err := tm.ParseAccess(pair.Access)
	if err != nil {
		t.Fatalf("ParseAccess: %v", err)
	}
	if claims.Subject != testAdminID {
		t.Errorf("sub = %q, want %q", claims.Subject, testAdminID)
	}
	if claims.Role != model.RoleAdmin {
		t.Errorf("role = %q, want %q", claims.Role, model.RoleAdmin)
	}
}

// Неверный пароль → ErrInvalidCredentials.
func TestLoginWithPasswordWrongPassword(t *testing.T) {
	svc, _, repo := newService(t, false)
	addUsernameAdmin(t, repo)

	if _, err := svc.LoginWithPassword(context.Background(), testUsername, "wrong-password"); !errors.Is(err, ErrInvalidCredentials) {
		t.Errorf("err = %v, want ErrInvalidCredentials", err)
	}
}

// Неизвестный username → ErrInvalidCredentials.
func TestLoginWithPasswordUnknownUser(t *testing.T) {
	svc, _, _ := newService(t, false) // без username-админа

	if _, err := svc.LoginWithPassword(context.Background(), "nobody", testPassword); !errors.Is(err, ErrInvalidCredentials) {
		t.Errorf("err = %v, want ErrInvalidCredentials", err)
	}
}

// Заблокированный admin → ErrInvalidCredentials.
func TestLoginWithPasswordInactive(t *testing.T) {
	svc, _, repo := newService(t, false)
	addUsernameAdmin(t, repo)
	u := repo.byUsername[testUsername]
	u.IsActive = false
	repo.add(u)

	if _, err := svc.LoginWithPassword(context.Background(), testUsername, testPassword); !errors.Is(err, ErrInvalidCredentials) {
		t.Errorf("err = %v, want ErrInvalidCredentials", err)
	}
}

// Пустой username/пароль → ErrInvalidCredentials (в БД не ходим).
func TestLoginWithPasswordEmpty(t *testing.T) {
	svc, _, repo := newService(t, false)
	addUsernameAdmin(t, repo)

	cases := []struct{ u, p string }{
		{"", testPassword},
		{testUsername, ""},
		{"", ""},
	}
	for _, c := range cases {
		if _, err := svc.LoginWithPassword(context.Background(), c.u, c.p); !errors.Is(err, ErrInvalidCredentials) {
			t.Errorf("LoginWithPassword(%q,%q) err = %v, want ErrInvalidCredentials", c.u, c.p, err)
		}
	}
}

// Бейдж-работник не может войти по паролю-пути (у него нет username) → ErrInvalidCredentials.
func TestLoginWithPasswordRejectsBadgeUser(t *testing.T) {
	svc, _, _ := newService(t, true) // есть бейдж-работник (login), username нет

	if _, err := svc.LoginWithPassword(context.Background(), testLogin, testSecret); !errors.Is(err, ErrInvalidCredentials) {
		t.Errorf("err = %v, want ErrInvalidCredentials", err)
	}
}

// Profile возвращает пользователя по id.
func TestProfile(t *testing.T) {
	svc, _, _ := newService(t, true)

	u, err := svc.Profile(context.Background(), testUserID)
	if err != nil {
		t.Fatalf("Profile: %v", err)
	}
	if u.Login != testLogin {
		t.Errorf("login = %q, want %q", u.Login, testLogin)
	}
}
