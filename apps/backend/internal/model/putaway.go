package model

import (
	"errors"
)

// Ошибки проведения размещения (P5-02). Все - отказ по существу: повтор их не исправит.
var (
	// ErrPutawayPosted - сеанс с этим идентификатором уже проведён (другой операцией).
	ErrPutawayPosted = errors.New("putaway already posted")
	// ErrEmptyPutaway - в сеансе нет ни одной строки.
	ErrEmptyPutaway = errors.New("putaway has no lines")
	// ErrPutawaySameCell - строка кладёт товар туда же, откуда взяла.
	ErrPutawaySameCell = errors.New("putaway line moves to the same cell")
	// ErrForeignCell - ячейка принадлежит другому складу, не складу документа.
	ErrForeignCell = errors.New("cell belongs to another warehouse")
	// ErrLoadUnitNotPlaced - короб ещё не лежит на складе (не оприходован приёмкой).
	ErrLoadUnitNotPlaced = errors.New("load unit is not placed")
	// ErrLoadUnitNested - короб вложен в паллету или сам содержит короба. Паллетная логика вне
	// объёма пилота, а частичный перенос дерева разорвал бы место коробов и их остаток.
	ErrLoadUnitNested = errors.New("nested load units are not supported")
	// ErrLooseStockShort - россыпи в ячейке приёмки меньше, чем просят разместить. Товар,
	// лежащий там же в коробах, россыпью не считается: иначе остаток ушёл бы из-под короба,
	// и его состав разошёлся бы с тем, что числится в ячейке.
	ErrLooseStockShort = errors.New("not enough loose stock in the receiving cell")
)

// ErrInvalidPutawayID - идентификатор документа размещения не UUID.
var ErrInvalidPutawayID = errors.New("putaway id must be a UUID")

// ErrInvalidTaskID - задание сеанса не указано или не UUID: размещения без задания нет (P5-02-1).
var ErrInvalidTaskID = errors.New("task id must be a UUID")
