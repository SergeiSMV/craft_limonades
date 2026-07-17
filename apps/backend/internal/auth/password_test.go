package auth

import "testing"

// Хеш и проверка: верный секрет проходит, неверный — нет.
func TestHashAndVerifyPassword(t *testing.T) {
	const secret = "23456781"

	hash, err := HashPassword(secret)
	if err != nil {
		t.Fatalf("HashPassword: %v", err)
	}
	if hash == secret {
		t.Fatal("хеш не должен совпадать с открытым секретом")
	}

	ok, err := VerifyPassword(secret, hash)
	if err != nil {
		t.Fatalf("VerifyPassword(верный): %v", err)
	}
	if !ok {
		t.Error("верный секрет должен проходить проверку")
	}

	ok, err = VerifyPassword("00000000", hash)
	if err != nil {
		t.Fatalf("VerifyPassword(неверный): %v", err)
	}
	if ok {
		t.Error("неверный секрет не должен проходить проверку")
	}
}

// Соль: два хеша одного и того же секрета различаются (случайная соль внутри argon2id).
func TestHashIsSalted(t *testing.T) {
	h1, err := HashPassword("11112222")
	if err != nil {
		t.Fatalf("HashPassword #1: %v", err)
	}
	h2, err := HashPassword("11112222")
	if err != nil {
		t.Fatalf("HashPassword #2: %v", err)
	}
	if h1 == h2 {
		t.Error("хеши одного секрета должны различаться (соль)")
	}
}
