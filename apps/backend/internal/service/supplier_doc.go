package service

import (
	"errors"
	"strings"
	"time"
	"unicode/utf8"

	"craftwms/internal/model"
)

// Ошибки документа поставщика (ADHOC-23).
var (
	// ErrEmptyDocNumber - не указан номер накладной (без номера - «б/н»).
	ErrEmptyDocNumber = errors.New("supplier document number is required")
	// ErrDocNumberTooLong - номер накладной длиннее 50 знаков.
	ErrDocNumberTooLong = errors.New("supplier document number must be at most 50 characters")
	// ErrInvalidDocDate - дата накладной не указана, не в формате DD-MM-YYYY или в будущем.
	ErrInvalidDocDate = errors.New("supplier document date must be DD-MM-YYYY and not in the future")
)

// docNumberMaxLen - предел длины номера; тот же CHECK стоит в базе.
const docNumberMaxLen = 50

// parseSupplierDoc проверяет номер и дату накладной поставщика (ADHOC-23).
//
// Что: номер - непустой свободный текст до 50 знаков; дата - DD-MM-YYYY, как у партий, и не
// в будущем. Зачем здесь, а не только на терминале: приёмка приходит и прямой ручкой, и из
// очереди, и правило должно быть одно.
//
// «Не в будущем» - с запасом в сутки: сервер живёт по UTC, а склад - по Москве, и в первые
// три часа московских суток сегодняшняя дата для сервера ещё «завтрашняя». Отказ кладовщику
// в его же сегодняшней накладной был бы хуже, чем пропуск даты на сутки вперёд.
func parseSupplierDoc(number, date string, now time.Time) (model.SupplierDoc, error) {
	number = strings.TrimSpace(number)
	if number == "" {
		return model.SupplierDoc{}, ErrEmptyDocNumber
	}
	if utf8.RuneCountInString(number) > docNumberMaxLen {
		return model.SupplierDoc{}, ErrDocNumberTooLong
	}
	d, err := time.Parse(dateLayoutIn, strings.TrimSpace(date))
	if err != nil {
		return model.SupplierDoc{}, ErrInvalidDocDate
	}
	if d.After(now.UTC().AddDate(0, 0, 1)) {
		return model.SupplierDoc{}, ErrInvalidDocDate
	}
	return model.SupplierDoc{Number: number, Date: d}, nil
}
