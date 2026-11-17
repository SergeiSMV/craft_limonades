package model

import (
	"errors"
)

// Виды документа движения (P6-01) - значения `movements.kind`.
//
// Перемещение и пополнение двигают одно и то же - ГЕ или товар между ячейками и коробами -
// и уходят одним отчётом «Движение», поэтому живут в одной таблице и различаются видом.
const (
	// MovementMove - перемещение: ГЕ целиком или товар - из ячейки или короба в ячейку или короб
	// (P6-02, P6-03).
	MovementMove = "move"
	// MovementReplenish - пополнение: та же механика, что у перемещения, - товар с количеством
	// и партией между ГЕ и россыпью в любых сочетаниях или ГЕ целиком (P6-05). Отличается
	// только видом документа: 1С и портал видят, зачем товар переехал.
	MovementReplenish = "replenish"
)

// Ошибки переноса ГЕ и проведения документа движения (P6-02). Все - отказ по существу:
// повтор их не исправит.
var (
	// ErrSameCell - ГЕ переносят туда, где она и так лежит.
	ErrSameCell = errors.New("load unit is already in the target cell")
	// ErrMovementPosted - документ движения с этим идентификатором уже проведён.
	ErrMovementPosted = errors.New("movement already posted")
	// ErrEmptyMovement - в документе движения нет ни одной строки.
	ErrEmptyMovement = errors.New("movement has no lines")
	// ErrUnknownMovementKind - вид документа не перемещение и не пополнение.
	ErrUnknownMovementKind = errors.New("unknown movement kind")
	// ErrReceivingCell - ячейка приёмки («ПРИЁМКА») в движении ни источник, ни приёмник: её
	// разносит задание на размещение (P5-02-1), иначе остаток задания разошёлся бы с ячейкой.
	// Исключение - источник-россыпь с меткой склада (ADHOC-55): её в задании нет.
	ErrReceivingCell = errors.New("receiving cell is emptied only by a putaway task")
	// ErrEmptyMovementLine - в строке нет ни ГЕ, ни товара.
	// У товара источник и приёмник - ровно по одному: ячейка или короб.
	ErrEmptyMovementLine = errors.New("movement line must have a load unit or goods with one source and one target")
	// ErrSamePlace - товар кладут туда же, откуда взяли: та же ячейка и тот же короб (или
	// россыпь).
	ErrSamePlace = errors.New("goods move to the same place")
	// ErrGoodsShort - в источнике меньше товара этой партии, чем просят перенести. Россыпью
	// считается остаток ячейки за вычетом того, что лежит в её коробах.
	ErrGoodsShort = errors.New("not enough goods at the source")
	// ErrWarehouseMismatch - товар кладут в короб другого внутреннего склада (P6-07-1):
	// короб принадлежит складу целиком, брак в «Основной» короб не кладётся, и наоборот.
	ErrWarehouseMismatch = errors.New("goods and load unit belong to different internal warehouses")
	// ErrMovementQty - количество товара в строке не положительное.
	ErrMovementQty = errors.New("goods quantity must be positive")
)

// ErrInvalidMovementID - идентификатор документа движения не UUID.
var ErrInvalidMovementID = errors.New("movement id must be a UUID")
