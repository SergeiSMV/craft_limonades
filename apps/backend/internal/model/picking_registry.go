package model

import (
	"errors"
	"strings"
	"unicode"
)

// ErrRegistryFile - файл реестра не принят целиком (нет листа или колонки, нет принятых строк,
// несколько дат): ошибка ввода оператора, а не сбой.
var ErrRegistryFile = errors.New("реестр не принят")

// GoodCodeLen - длина кода товара в справочнике номенклатуры 1С («00000016147»).
const GoodCodeLen = 11

// NormalizeGoodCode приводит код товара из «Реестра» 1С к формату справочника.
//
// Что: «00-00001101» → «00000001101», «00000016147» → как есть, «16147» → «00000016147».
// Зачем: реестр отдаёт код в двух видах, а номенклатура хранит одиннадцать цифр без
// разделителей - сопоставление идёт по строке кода.
// Как: выкидываем всё, кроме цифр, и дополняем нулями слева до GoodCodeLen. ok=false - в коде
// нет ни одной цифры или цифр больше GoodCodeLen: такой код не из справочника, строка уходит в
// отчёт, а не сопоставляется наугад.
func NormalizeGoodCode(raw string) (code string, ok bool) {
	var b strings.Builder
	for _, r := range raw {
		if r >= '0' && r <= '9' {
			b.WriteRune(r)
		}
	}
	digits := b.String()
	if digits == "" || len(digits) > GoodCodeLen {
		return "", false
	}
	return strings.Repeat("0", GoodCodeLen-len(digits)) + digits, true
}

// homoglyphs - латинские буквы, неотличимые на глаз от кириллических, → кириллическая пара.
// Набор из docs/picking.md: А/A, В/B, С/C, Е/E, Н/H, К/K, М/M, О/O, Р/P, Т/T, Х/X.
var homoglyphs = map[rune]rune{
	'A': 'А', 'B': 'В', 'C': 'С', 'E': 'Е', 'H': 'Н', 'K': 'К',
	'M': 'М', 'O': 'О', 'P': 'Р', 'T': 'Т', 'X': 'Х',
}

// CellAddressKey - ключ сверки адреса ячейки из реестра с адресом WMS.
//
// Что: «C-1-1-1» (латиница) и «С-1-1-1» (кириллица) дают один ключ; «D-Н-П» и «D-H-П» - тоже.
// Зачем: 1С смешивает алфавиты в адресах (`В-…`, `С-…` кириллицей, `D-…`, `M1-…` латиницей), а
// в WMS стеллажи записаны латиницей - по строке как есть адреса не совпадают.
// Как: верхний регистр, пробелы по краям и внутри убраны, латинские двойники заменены
// кириллицей. Ключ только для сравнения: в план сборки берётся адрес WMS, а не ключ.
// Буквы без пары остаются как есть, поэтому «D» и «Д» - разные стеллажи.
func CellAddressKey(address string) string {
	var b strings.Builder
	for _, r := range strings.ToUpper(address) {
		if unicode.IsSpace(r) {
			continue
		}
		if c, ok := homoglyphs[r]; ok {
			r = c
		}
		b.WriteRune(r)
	}
	return b.String()
}

// RegistryGood - товар справочника, найденный по коду строки реестра: что нужно сборке, чтобы
// показать позицию и понять, собирать ли её марками.
type RegistryGood struct {
	ID       string
	Code     string
	Name     string
	CZMarked bool // маркируемый - собирается только марками (docs/picking.md, «Подбор»)
}
