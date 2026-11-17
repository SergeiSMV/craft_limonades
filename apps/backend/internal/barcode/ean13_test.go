package barcode_test

import (
	"errors"
	"strings"
	"testing"

	"craftwms/internal/barcode"
)

// Контрольная цифра EAN-13 (P4-07): её смысл в том, чтобы поймать опечатку ручного набора,
// поэтому проверяем на реальных кодах, а не на собственных вычислениях.
func TestCheckDigitEAN13(t *testing.T) {
	cases := []struct {
		body  string // первые 12 знаков
		check int
		name  string
	}{
		{"590123412345", 7, "пример из спецификации GS1"},
		{"400638133393", 1, "реальный код товара"},
		{"978014300723", 4, "ISBN-13 - та же схема контроля"},
		{"000000000000", 0, "нули дают нулевую контрольную"},
	}
	for _, c := range cases {
		if got := barcode.CheckDigitEAN13(c.body); got != c.check {
			t.Errorf("%s: %s → %d, ожидалось %d", c.name, c.body, got, c.check)
		}
	}
}

func TestValidEAN13(t *testing.T) {
	if !barcode.ValidEAN13("5901234123457") {
		t.Error("верный код признан неверным")
	}
	// Одна изменённая цифра обязана ломать проверку - ради этого контрольная цифра и нужна.
	if barcode.ValidEAN13("5901234123451") {
		t.Error("код с неверной контрольной цифрой принят")
	}
	// Перестановка соседних цифр - самая частая опечатка при ручном наборе.
	if barcode.ValidEAN13("5901234123547") {
		t.Error("перестановка цифр не поймана")
	}
	for _, bad := range []string{"", "590123412345", "59012341234567", "59012341234a7"} {
		if barcode.ValidEAN13(bad) {
			t.Errorf("мусор принят за EAN-13: %q", bad)
		}
	}
}

func TestInternal(t *testing.T) {
	code, err := barcode.Internal(barcode.InternalPrefix, 1)
	if err != nil {
		t.Fatalf("Internal: %v", err)
	}
	if len(code) != 13 {
		t.Fatalf("длина кода %d, ожидалось 13: %s", len(code), code)
	}
	if !strings.HasPrefix(code, "20") {
		t.Errorf("префикс кода: %s", code)
	}
	// Собранный код обязан проходить собственную проверку - иначе сканер его отвергнет.
	if !barcode.ValidEAN13(code) {
		t.Errorf("собранный код не проходит проверку: %s", code)
	}
	if !barcode.IsInternalEAN13(code) {
		t.Errorf("собранный код не опознан как внутренний: %s", code)
	}
}

func TestInternal_serialPadding(t *testing.T) {
	// Серийный номер занимает ровно десять знаков: без ведущих нулей длина кода поехала бы,
	// и первые выданные коды оказались бы короче тринадцати цифр.
	code, err := barcode.Internal(20, 42)
	if err != nil {
		t.Fatalf("Internal: %v", err)
	}
	if code[:12] != "200000000042" {
		t.Errorf("тело кода %q, ожидалось 200000000042", code[:12])
	}

	// Наибольший номер тоже обязан помещаться.
	last, err := barcode.Internal(20, 9_999_999_999)
	if err != nil {
		t.Fatalf("Internal(max): %v", err)
	}
	if len(last) != 13 || !barcode.ValidEAN13(last) {
		t.Errorf("код наибольшего номера неверен: %s", last)
	}
}

func TestInternal_borders(t *testing.T) {
	// Весь разрешённый диапазон префиксов обязан работать: 20 занят сейчас, остальные
	// оставлены на будущее (например, весовые коды).
	for prefix := 20; prefix <= 29; prefix++ {
		if _, err := barcode.Internal(prefix, 1); err != nil {
			t.Errorf("префикс %d отклонён: %v", prefix, err)
		}
	}
	// Вне диапазона код может столкнуться с кодом настоящего производителя.
	for _, prefix := range []int{0, 19, 30, 99} {
		if _, err := barcode.Internal(prefix, 1); !errors.Is(err, barcode.ErrPrefixOutOfRange) {
			t.Errorf("префикс %d принят: %v", prefix, err)
		}
	}
	if _, err := barcode.Internal(20, 10_000_000_000); !errors.Is(err, barcode.ErrSerialOutOfRange) {
		t.Error("серийный номер сверх десяти цифр принят")
	}
}

func TestInternal_uniquePerSerial(t *testing.T) {
	// Разные номера дают разные коды - на этом держится уникальность ШК.
	seen := make(map[string]int64, 1000)
	for serial := int64(1); serial <= 1000; serial++ {
		code, err := barcode.Internal(20, serial)
		if err != nil {
			t.Fatalf("Internal(%d): %v", serial, err)
		}
		if prev, dup := seen[code]; dup {
			t.Fatalf("код %s выдан дважды: номера %d и %d", code, prev, serial)
		}
		seen[code] = serial
	}
}

func TestIsInternalEAN13(t *testing.T) {
	// Чужой код производителя внутренним не считается.
	if barcode.IsInternalEAN13("5901234123457") {
		t.Error("код производителя принят за внутренний")
	}
	// Код с верным префиксом, но битой контрольной цифрой - тоже нет.
	if barcode.IsInternalEAN13("2000000000421") {
		t.Error("код с неверной контрольной цифрой принят за внутренний")
	}
}
