// Package barcode - построение и проверка штрихкодов (P4-07).
//
// Отдельный пакет, а не функция в сервисе: здесь чистая арифметика символики, без БД, HTTP
// и доменных понятий склада. Её удобно проверять таблицей известных кодов, и она понадобится
// не только генерации - печать товарного ярлыка (P4-08) обязана уметь проверить код перед тем,
// как вывести его на этикетку.
package barcode

import (
	"errors"
	"fmt"
	"strings"
)

// Ошибки построения внутреннего ШК.
var (
	// ErrPrefixOutOfRange - префикс вне диапазона 20-29, зарезервированного GS1 под внутреннее
	// использование. Вне его код может столкнуться с кодом настоящего производителя.
	ErrPrefixOutOfRange = errors.New("internal barcode prefix must be in 20..29")
	// ErrSerialOutOfRange - серийный номер не помещается в десять цифр.
	ErrSerialOutOfRange = errors.New("internal barcode serial must fit in 10 digits")
)

const (
	// InternalPrefix - префикс внутренних ШК склада.
	//
	// 20 из разрешённого диапазона 20-29; остальные девять остаются свободными на случай,
	// когда понадобится отличать разные виды внутренних кодов - например, весовые, где
	// в теле кода лежит масса. Занимать весь диапазон одним смыслом сейчас незачем.
	InternalPrefix = 20

	// serialDigits - сколько цифр остаётся под серийный номер: 13 всего минус два на префикс
	// и одна на контрольную цифру.
	serialDigits = 10

	// maxSerial - наибольший серийный номер, помещающийся в [serialDigits].
	maxSerial = 9_999_999_999
)

// Internal собирает внутренний EAN-13 из префикса и серийного номера.
//
// Что: `PP` + серийный номер в десяти цифрах с ведущими нулями + контрольная цифра.
// Зачем контрольная цифра: она ловит опечатку при ручном наборе кода, а не только ошибку скана,
// - именно за это EAN-13 и выбран вместо Code128 (решение заказчика, вопрос №4).
func Internal(prefix int, serial int64) (string, error) {
	if prefix < 20 || prefix > 29 {
		return "", fmt.Errorf("%w: %d", ErrPrefixOutOfRange, prefix)
	}
	if serial < 0 || serial > maxSerial {
		return "", fmt.Errorf("%w: %d", ErrSerialOutOfRange, serial)
	}
	body := fmt.Sprintf("%02d%0*d", prefix, serialDigits, serial)
	return body + string(rune('0'+CheckDigitEAN13(body))), nil
}

// CheckDigitEAN13 считает контрольную цифру по двенадцати знакам кода.
//
// Как: цифры взвешиваются чередованием 1 и 3, начиная с 1 для первой; контрольная дополняет
// сумму до ближайшего десятка. Нецифровые знаки считаются нулём - проверять форму должен
// вызывающий через [ValidEAN13], а молчаливая паника здесь никому не помогла бы.
func CheckDigitEAN13(body string) int {
	sum := 0
	for i, r := range body {
		d := int(r - '0')
		if d < 0 || d > 9 {
			d = 0
		}
		if i%2 == 0 {
			sum += d
		} else {
			sum += 3 * d
		}
	}
	return (10 - sum%10) % 10
}

// ValidEAN13 проверяет, что строка - тринадцать цифр с верной контрольной цифрой.
func ValidEAN13(code string) bool {
	code = strings.TrimSpace(code)
	if len(code) != 13 {
		return false
	}
	for _, r := range code {
		if r < '0' || r > '9' {
			return false
		}
	}
	return CheckDigitEAN13(code[:12]) == int(code[12]-'0')
}

// IsInternalEAN13 - похож ли код на выданный нами: верный EAN-13 с префиксом из диапазона 20-29.
//
// ⚠ Это проверка ФОРМЫ, а не принадлежности. Выгрузка 1С может принести внутренний код чужой
// системы с тем же префиксом, и он пройдёт эту проверку. Принадлежность хранится флагом
// `barcodes.is_internal` - тот же приём, что у дефолтной ячейки: признак хранится, а не
// вычисляется из строки.
func IsInternalEAN13(code string) bool {
	if !ValidEAN13(code) {
		return false
	}
	return code[0] == '2'
}
