package auth

import (
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

func newTM() *TokenManager {
	return NewTokenManager("test-secret", time.Hour, 24*time.Hour)
}

// Access-токен: round-trip сохраняет sub, role и тип.
func TestIssueAndParseAccess(t *testing.T) {
	m := newTM()

	tok, err := m.IssueAccess("user-1", "admin")
	if err != nil {
		t.Fatalf("IssueAccess: %v", err)
	}

	claims, err := m.ParseAccess(tok)
	if err != nil {
		t.Fatalf("ParseAccess: %v", err)
	}
	if claims.Subject != "user-1" {
		t.Errorf("sub = %q, want %q", claims.Subject, "user-1")
	}
	if claims.Role != "admin" {
		t.Errorf("role = %q, want %q", claims.Role, "admin")
	}
	if claims.Typ != typeAccess {
		t.Errorf("typ = %q, want %q", claims.Typ, typeAccess)
	}
}

// Refresh-токен: round-trip; роль в refresh не кладём (перечитывается из БД).
func TestIssueAndParseRefresh(t *testing.T) {
	m := newTM()

	tok, err := m.IssueRefresh("user-2")
	if err != nil {
		t.Fatalf("IssueRefresh: %v", err)
	}

	claims, err := m.ParseRefresh(tok)
	if err != nil {
		t.Fatalf("ParseRefresh: %v", err)
	}
	if claims.Subject != "user-2" {
		t.Errorf("sub = %q, want %q", claims.Subject, "user-2")
	}
	if claims.Role != "" {
		t.Errorf("role = %q, want empty", claims.Role)
	}
	if claims.Typ != typeRefresh {
		t.Errorf("typ = %q, want %q", claims.Typ, typeRefresh)
	}
}

// Разделение типов: access нельзя проверить как refresh и наоборот.
func TestTokenTypeIsolation(t *testing.T) {
	m := newTM()

	access, _ := m.IssueAccess("u", "admin")
	if _, err := m.ParseRefresh(access); err == nil {
		t.Error("access-токен не должен приниматься как refresh")
	}

	refresh, _ := m.IssueRefresh("u")
	if _, err := m.ParseAccess(refresh); err == nil {
		t.Error("refresh-токен не должен приниматься как access")
	}
}

// Просроченный токен отклоняется.
func TestParseRejectsExpired(t *testing.T) {
	m := NewTokenManager("s", -time.Minute, time.Hour) // access уже истёк на момент выпуска
	tok, err := m.IssueAccess("u", "")
	if err != nil {
		t.Fatalf("IssueAccess: %v", err)
	}
	if _, err := m.ParseAccess(tok); err == nil {
		t.Error("просроченный токен должен отклоняться")
	}
}

// Чужой секрет подписи: токен от другого менеджера не проходит.
func TestParseRejectsWrongSecret(t *testing.T) {
	signer := NewTokenManager("secret-1", time.Hour, time.Hour)
	verifier := NewTokenManager("secret-2", time.Hour, time.Hour)

	tok, _ := signer.IssueAccess("u", "")
	if _, err := verifier.ParseAccess(tok); err == nil {
		t.Error("токен с чужим секретом должен отклоняться")
	}
}

// Мусор вместо токена отклоняется.
func TestParseRejectsGarbage(t *testing.T) {
	m := newTM()
	if _, err := m.ParseAccess("not-a-jwt"); err == nil {
		t.Error("невалидная строка должна отклоняться")
	}
}

// Защита от подмены алгоритма: токен с alg=none отклоняется.
func TestParseRejectsAlgNone(t *testing.T) {
	m := newTM()

	claims := Claims{
		Typ: typeAccess,
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   "u",
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Hour)),
		},
	}
	unsigned := jwt.NewWithClaims(jwt.SigningMethodNone, claims)
	tok, err := unsigned.SignedString(jwt.UnsafeAllowNoneSignatureType)
	if err != nil {
		t.Fatalf("подготовка alg=none токена: %v", err)
	}

	if _, err := m.ParseAccess(tok); err == nil {
		t.Error("токен с alg=none должен отклоняться (защита от подмены алгоритма)")
	}
}
