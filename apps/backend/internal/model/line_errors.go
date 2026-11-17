package model

import (
	"errors"
	"fmt"
	"strings"
)

// LineRejection - строка документа, отклонённая по существу (ADHOC-40).
type LineRejection struct {
	Line  int    // номер строки в документе, с 1
	Label string // что это за строка - для человека: товар, партия, откуда и куда
	Err   error  // причина - ошибка репозитория
}

// DocumentLinesError - документ отклонён, и названы ВСЕ его плохие строки (ADHOC-40, долг 26).
//
// Зачем: документ проводится целиком или не проводится вовсе, и раньше проверка обрывалась на
// первой плохой строке. Кладовщик с тремя плохими строками узнавал о них по одной за попытку,
// а видел английский код без указания строки.
// Как: текст ошибки - по-русски, строка названа содержимым: терминал показывает его как есть.
// Unwrap отдаёт причины строк, поэтому errors.Is по ним работает, как и раньше.
type DocumentLinesError struct {
	Total int // строк в документе
	Lines []LineRejection
}

func (e *DocumentLinesError) Error() string {
	var b strings.Builder
	fmt.Fprintf(&b, "Отклонено строк: %d из %d", len(e.Lines), e.Total)
	for _, l := range e.Lines {
		fmt.Fprintf(&b, "\n• %s: %s", l.Label, LineReason(l.Err))
	}
	return b.String()
}

// Unwrap - причины всех отклонённых строк.
func (e *DocumentLinesError) Unwrap() []error {
	out := make([]error, 0, len(e.Lines))
	for _, l := range e.Lines {
		out = append(out, l.Err)
	}
	return out
}

// LineReason - причина отказа строки по-русски; незнакомая ошибка - её текст как есть.
func LineReason(err error) string {
	switch {
	case errors.Is(err, ErrGoodsShort), errors.Is(err, ErrInsufficientStock):
		return "в источнике не хватает товара этой партии"
	case errors.Is(err, ErrLooseStockShort):
		return "в ячейке приёмки не хватает россыпи"
	case errors.Is(err, ErrCZMarksRequired):
		return "маркируемый товар перемещается только сканом марок"
	case errors.Is(err, ErrCZMarksQtyMismatch):
		return "марок не столько, сколько единиц в строке"
	case errors.Is(err, ErrCZMarkNotAtSource):
		return "марки нет в источнике строки или она уже не на складе - её могли переместить с " +
			"другого терминала: обновите данные и отсканируйте снова"
	case errors.Is(err, ErrCZMarkBatchMismatch):
		return "марка другого товара или другой партии"
	// Ввод остатков с коробами и марками (ADHOC-46).
	case errors.Is(err, ErrLoadUnitExists):
		return "короб уже есть в учёте склада - его не вводят заново"
	case errors.Is(err, ErrCZAggregateExists):
		return "короб или упаковка ЧЗ уже есть в учёте склада"
	case errors.Is(err, ErrCZMarkExists):
		return "марка уже есть в учёте склада"
	case errors.Is(err, ErrEntryDuplicate):
		return "уже введено в другой ячейке этого прохода"
	case errors.Is(err, ErrEntryCellHasMarks):
		return "в ячейке уже лежат марки этого товара и партии россыпью - пересчёт их не учтёт"
	case errors.Is(err, ErrEntryEmptyBox):
		return "в коробе нет товара"
	case errors.Is(err, ErrLoadUnitNotFound):
		return "короб не найден"
	case errors.Is(err, ErrLoadUnitNotPlaced):
		return "короб не размещён на складе"
	case errors.Is(err, ErrLoadUnitNested):
		return "вложенные короба не поддерживаются"
	case errors.Is(err, ErrSameCell), errors.Is(err, ErrPutawaySameCell):
		return "уже лежит в этой ячейке"
	case errors.Is(err, ErrSamePlace):
		return "товар кладут туда же, откуда взяли"
	case errors.Is(err, ErrWarehouseMismatch):
		return "товар и короб - с разных внутренних складов"
	case errors.Is(err, ErrPickingMarkInPicking):
		return "марка уже взята в сборку: она в коробе отгрузки"
	case errors.Is(err, ErrReceivingCell):
		return "ячейку приёмки разносит только задание на размещение"
	case errors.Is(err, ErrForeignCell):
		return "ячейка другого склада"
	case errors.Is(err, ErrUnknownReference):
		return "ячейка, товар или короб не найдены"
	case errors.Is(err, ErrNotInTask):
		return "этого нет в задании на размещение"
	case errors.Is(err, ErrExceedsTask):
		return "больше, чем осталось по заданию"
	case errors.Is(err, ErrMovementQty):
		return "количество должно быть больше нуля"
	case errors.Is(err, ErrEmptyMovementLine):
		return "строка заполнена неверно"
	default:
		return err.Error()
	}
}
