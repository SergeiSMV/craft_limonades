package auth

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
)

// ErrBadgeKey — ключ бейджей задан неверно: нужно 64 шестнадцатеричных знака (32 байта).
var ErrBadgeKey = errors.New("BADGE_KEY: нужно 64 шестнадцатеричных знака (openssl rand -hex 32)")

// errBadgeOpen — шифртекст не расшифровался: другой ключ, чужая строка или порча.
var errBadgeOpen = errors.New("номер бейджа не расшифровался")

// BadgeCipher — шифрование секрета бейджа для печати (ADHOC-65).
//
// Что: AES-256-GCM, nonce — в начале шифртекста, связанные данные — логин (первые 8 цифр).
// Зачем: бейдж печатается тем же номером, что выдан, а хеш argon2 (им проверяется вход) номер
// не возвращает. Логин в связанных данных привязывает шифртекст к своей строке: подложенный
// от другого пользователя не расшифруется. Ключ живёт только в окружении бэкенда, в базе и
// дампах его нет.
type BadgeCipher struct {
	aead cipher.AEAD
}

// NewBadgeCipher разбирает ключ из BADGE_KEY: 64 шестнадцатеричных знака.
func NewBadgeCipher(hexKey string) (*BadgeCipher, error) {
	key, err := hex.DecodeString(strings.TrimSpace(hexKey))
	if err != nil || len(key) != 32 {
		return nil, ErrBadgeKey
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("ключ бейджей: %w", err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("ключ бейджей: %w", err)
	}
	return &BadgeCipher{aead: aead}, nil
}

// Seal шифрует секрет бейджа логином-связанными данными; nonce — случайный, в начале.
func (c *BadgeCipher) Seal(login, secret string) ([]byte, error) {
	nonce := make([]byte, c.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, fmt.Errorf("nonce бейджа: %w", err)
	}
	return c.aead.Seal(nonce, nonce, []byte(secret), []byte(login)), nil
}

// Open расшифровывает секрет бейджа; ошибка — не тот ключ, не та строка или порча.
func (c *BadgeCipher) Open(login string, sealed []byte) (string, error) {
	n := c.aead.NonceSize()
	if len(sealed) <= n {
		return "", errBadgeOpen
	}
	plain, err := c.aead.Open(nil, sealed[:n], sealed[n:], []byte(login))
	if err != nil {
		return "", errBadgeOpen
	}
	return string(plain), nil
}
