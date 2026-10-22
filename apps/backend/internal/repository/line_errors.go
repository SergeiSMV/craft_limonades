package repository

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/shopspring/decimal"
)

// LineRejection — строка документа, отклонённая по существу (ADHOC-40).
type LineRejection struct {
	Line  int    // номер строки в документе, с 1
	Label string // что это за строка — для человека: товар, партия, откуда и куда
	Err   error  // причина — ошибка репозитория
}

// DocumentLinesError — документ отклонён, и названы ВСЕ его плохие строки (ADHOC-40, долг 26).
//
// Зачем: документ проводится целиком или не проводится вовсе, и раньше проверка обрывалась на
// первой плохой строке. Кладовщик с тремя плохими строками узнавал о них по одной за попытку,
// а видел английский код без указания строки.
// Как: текст ошибки — по-русски, строка названа содержимым: терминал показывает его как есть.
// Unwrap отдаёт причины строк, поэтому errors.Is по ним работает, как и раньше.
type DocumentLinesError struct {
	Total int // строк в документе
	Lines []LineRejection
}

func (e *DocumentLinesError) Error() string {
	var b strings.Builder
	fmt.Fprintf(&b, "Отклонено строк: %d из %d", len(e.Lines), e.Total)
	for _, l := range e.Lines {
		fmt.Fprintf(&b, "\n• %s: %s", l.Label, lineReason(l.Err))
	}
	return b.String()
}

// Unwrap — причины всех отклонённых строк.
func (e *DocumentLinesError) Unwrap() []error {
	out := make([]error, 0, len(e.Lines))
	for _, l := range e.Lines {
		out = append(out, l.Err)
	}
	return out
}

// lineRejections — ошибки, которыми отказывает одна строка документа, не задевая остальные.
// Всё прочее (сбой базы, документ уже проведён, задание не то) обрывает проверку сразу.
var lineRejections = []error{
	ErrEmptyMovementLine, ErrMovementQty, ErrSamePlace, ErrGoodsShort, ErrWarehouseMismatch,
	ErrReceivingCell, ErrSameCell, ErrLoadUnitNotFound, ErrLoadUnitNotPlaced, ErrLoadUnitNested,
	ErrForeignCell, ErrUnknownReference, ErrInsufficientStock,
	ErrPutawaySameCell, ErrLooseStockShort, ErrNotInTask, ErrExceedsTask,
}

// isLineRejection — отказ ли это одной строки.
func isLineRejection(err error) bool {
	for _, target := range lineRejections {
		if errors.Is(err, target) {
			return true
		}
	}
	return false
}

// lineReason — причина отказа строки по-русски; незнакомая ошибка — её текст как есть.
func lineReason(err error) string {
	switch {
	case errors.Is(err, ErrGoodsShort), errors.Is(err, ErrInsufficientStock):
		return "в источнике не хватает товара этой партии"
	case errors.Is(err, ErrLooseStockShort):
		return "в ячейке приёмки не хватает россыпи"
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
		return "товар и короб — с разных внутренних складов"
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

// docLineSavepoint — имя точки отката строки. Одно на все строки: точка ставится заново перед
// каждой и снимается после, вложенности нет.
const docLineSavepoint = "doc_line"

// tryLine выполняет строку документа под точкой отката (ADHOC-40).
//
// Что: строка, отклонённая по существу, откатывается одна, и документ проверяется дальше так,
// будто её не было; её причина возвращается первым значением.
// Зачем: назвать все плохие строки сразу. Откат нужен не только ради чистого состояния —
// ошибка SQL внутри строки (ссылка на несуществующее) переводит транзакцию Postgres в
// «прерванную», и без отката к точке следующая строка упала бы уже на этом.
// Как: SAVEPOINT → строка → RELEASE; при отказе строки — ROLLBACK TO SAVEPOINT. Любая другая
// ошибка — второе значение: проверку надо оборвать, транзакция откатится целиком.
func tryLine(ctx context.Context, q Querier, line func() error) (rejected, fatal error) {
	if _, err := q.Exec(ctx, "SAVEPOINT "+docLineSavepoint); err != nil {
		return nil, fmt.Errorf("точка отката строки: %w", err)
	}
	err := missingReference(line())
	if err == nil {
		if _, err := q.Exec(ctx, "RELEASE SAVEPOINT "+docLineSavepoint); err != nil {
			return nil, fmt.Errorf("снять точку отката строки: %w", err)
		}
		return nil, nil
	}
	if !isLineRejection(err) {
		return nil, err
	}
	if _, rbErr := q.Exec(ctx, "ROLLBACK TO SAVEPOINT "+docLineSavepoint); rbErr != nil {
		return nil, fmt.Errorf("откатить строку: %w", rbErr)
	}
	return err, nil
}

//* --- Подписи строк для человека --- *//

// goodText — «название · партия ДД.ММ.ГГГГ · количество ед.».
func goodText(ctx context.Context, q Querier, goodID, productionDate string, qty decimal.Decimal) string {
	name, uom := "товар ?", ""
	_ = q.QueryRow(ctx, `SELECT name, uom FROM goods WHERE id = $1::uuid`, goodID).Scan(&name, &uom)
	parts := []string{name}
	if productionDate != "" {
		parts = append(parts, "партия "+ruDate(productionDate))
	}
	if !qty.IsZero() {
		parts = append(parts, strings.TrimSpace(strings.ReplaceAll(qty.String(), ".", ",")+" "+uom))
	}
	return strings.Join(parts, " · ")
}

// cellText — адрес ячейки; не нашлась — «ячейка ?».
func cellText(ctx context.Context, q Querier, cellID string) string {
	addr := "ячейка ?"
	_ = q.QueryRow(ctx, `SELECT address FROM cells WHERE id = $1::uuid`, cellID).Scan(&addr)
	return addr
}

// boxText — «короб XXXX XXXX»: короткий код, как на ярлыке (хвост UUID, две четвёрки).
func boxText(loadUnitID string) string {
	hex := strings.ToUpper(strings.ReplaceAll(loadUnitID, "-", ""))
	if len(hex) > 8 {
		hex = hex[len(hex)-8:]
	}
	if len(hex) == 8 {
		hex = hex[:4] + " " + hex[4:]
	}
	return "короб " + hex
}

// ruDate — 'ГГГГ-ММ-ДД' → 'ДД.ММ.ГГГГ'; иной вид — как есть.
func ruDate(iso string) string {
	if len(iso) == 10 && iso[4] == '-' && iso[7] == '-' {
		return iso[8:10] + "." + iso[5:7] + "." + iso[0:4]
	}
	return iso
}
