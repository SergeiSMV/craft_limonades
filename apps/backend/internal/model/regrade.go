package model

import (
	"errors"
)

// Отказы перепривязки ШК и правки привязок при марках ЧЗ на складе (ADHOC-53). Тексты -
// по-русски: ТСД показывает их дословно, и в окне ответа ручки, и в отказе операции очереди.
var (
	// ErrBarcodeHasCZStock - у ШК на складе есть марки: отвязка оставила бы их без товара в
	// справочнике, ШК можно только перепривязать.
	ErrBarcodeHasCZStock = errors.New("на складе есть марки ЧЗ с этим ШК - отвязать нельзя, перепривяжите ШК к правильному товару")
	// ErrBarcodeMarksOtherGood - привязка ШК к товару, хотя марки этого GTIN на складе числятся
	// за другим: тихо разошлись бы ШК и учёт.
	ErrBarcodeMarksOtherGood = errors.New("марки ЧЗ с этим ШК числятся на складе за другим товаром - перепривяжите ШК из карточки того товара")
	// ErrRegradeNotBound - ШК не привязан: перепривязывать нечего.
	ErrRegradeNotBound = errors.New("ШК не привязан к товару")
	// ErrRegradeSameGood - ШК уже за этим товаром.
	ErrRegradeSameGood = errors.New("ШК уже привязан к этому товару")
	// ErrRegradeOpenProblem - часть марок в открытой проблеме склада или ждёт отгрузки возврата.
	ErrRegradeOpenProblem = errors.New("часть марок - в открытой проблеме склада или ждёт отгрузки возврата поставщику: сначала завершите её")
	// ErrRegradeCellCounting - ячейка с марками сейчас пересчитывается.
	ErrRegradeCellCounting = errors.New("ячейка с марками сейчас на пересчёте - дождитесь конца подсчёта")
	// ErrRegradeBoxNotPlaced - короб с марками не стоит в ячейке.
	ErrRegradeBoxNotPlaced = errors.New("короб с марками не размещён в ячейке")
)

// IsRegradeRefusal - отказ перепривязки по существу: его текст - для кладовщика.
func IsRegradeRefusal(err error) bool {
	for _, e := range []error{ErrRegradeNotBound, ErrRegradeSameGood, ErrRegradeOpenProblem,
		ErrRegradeCellCounting, ErrRegradeBoxNotPlaced, ErrGoodNotFound} {
		if errors.Is(err, e) {
			return true
		}
	}
	return false
}
