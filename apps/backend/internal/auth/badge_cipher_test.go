package auth

import (
	"errors"
	"strings"
	"testing"
)

const testBadgeKey = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

// Секрет бейджа шифруется и расшифровывается тем же ключом и логином; nonce каждый раз новый.
func TestBadgeCipherRoundTrip(t *testing.T) {
	c, err := NewBadgeCipher(testBadgeKey)
	if err != nil {
		t.Fatalf("NewBadgeCipher: %v", err)
	}
	a, err := c.Seal("10000000", "23456781")
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	b, _ := c.Seal("10000000", "23456781")
	if string(a) == string(b) {
		t.Fatal("два шифртекста одного секрета совпали - nonce не случайный")
	}
	got, err := c.Open("10000000", a)
	if err != nil || got != "23456781" {
		t.Fatalf("Open = %q, %v", got, err)
	}
}

// Чужой логин, другой ключ и обрезанный шифртекст - отказ, а не мусорный номер.
func TestBadgeCipherRejects(t *testing.T) {
	c, _ := NewBadgeCipher(testBadgeKey)
	sealed, _ := c.Seal("10000000", "23456781")
	if _, err := c.Open("10000001", sealed); err == nil {
		t.Fatal("шифртекст другой строки расшифровался")
	}
	other, _ := NewBadgeCipher(strings.Repeat("ab", 32))
	if _, err := other.Open("10000000", sealed); err == nil {
		t.Fatal("расшифровалось другим ключом")
	}
	if _, err := c.Open("10000000", sealed[:5]); err == nil {
		t.Fatal("обрезанный шифртекст расшифровался")
	}
}

// Ключ - ровно 32 байта шестнадцатерично.
func TestNewBadgeCipherBadKey(t *testing.T) {
	for _, k := range []string{"", "abc", strings.Repeat("zz", 32), strings.Repeat("ab", 16)} {
		if _, err := NewBadgeCipher(k); !errors.Is(err, ErrBadgeKey) {
			t.Errorf("ключ %q: ошибка %v, ждали ErrBadgeKey", k, err)
		}
	}
}
