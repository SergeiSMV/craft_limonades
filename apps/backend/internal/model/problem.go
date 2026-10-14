package model

// Проблемы склада (P6-07-1): пометка короба или товара другим внутренним складом — брак,
// изолятор и т. п. (ADR-0016). Брак — лишь метка и программная изоляция: товар остаётся
// в той же ячейке и перемещается как любой другой.

// Причины проблемы — фиксированный список (решение 2026-10-14). Значения лежат в БД под CHECK —
// менять только миграцией. Склад назначения причина не диктует: его выбирает кладовщик.
const (
	ProblemReasonBreakage    = "breakage"     // бой
	ProblemReasonSpoilage    = "spoilage"     // порча
	ProblemReasonExpired     = "expired"      // просрок
	ProblemReasonForeignMark = "foreign_mark" // не наша марка ЧЗ
	ProblemReasonOther       = "other"        // прочее — с обязательным комментарием
)

// ProblemReasons — все причины, в порядке показа.
var ProblemReasons = []string{
	ProblemReasonBreakage, ProblemReasonSpoilage, ProblemReasonExpired,
	ProblemReasonForeignMark, ProblemReasonOther,
}

// InternalWarehouse — внутренний склад для выбора на ТСД: куда пометить товар.
type InternalWarehouse struct {
	ID        string
	Code      string
	Name      string
	IsDefault bool
}
