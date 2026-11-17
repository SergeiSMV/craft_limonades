package model

import (
	"errors"
)

// Ошибки применения приёмки из очереди (P4-09).
var (
	// ErrNoDefaultCell - у склада нет ячейки приёмки по умолчанию, а строка ячейку не указала.
	ErrNoDefaultCell = errors.New("warehouse has no default cell")
	// ErrUnknownReference - документ ссылается на то, чего нет в справочниках (склад, поставщик,
	// товар, ячейка). Устройство собирает приёмку по своему кэшу, и между сборкой и отправкой
	// справочник мог измениться; это разбирается человеком, а не повтором.
	ErrUnknownReference = errors.New("receipt references a missing catalog entry")
)

// Ошибки батча операций.
var (
	// ErrEmptyBatch - прислан пустой список операций.
	ErrEmptyBatch = errors.New("operations list is empty")
	// ErrBatchTooLarge - операций больше MaxBatchOperations.
	ErrBatchTooLarge = errors.New("too many operations in one batch")
	// ErrInvalidOperationID - operation_id не UUID.
	ErrInvalidOperationID = errors.New("operation_id must be a UUID")
	// ErrNoOperationRight - у должности нет права на операцию этого вида (ADHOC-50). Текст -
	// для экрана ТСД, он показывает отказ дословно.
	ErrNoOperationRight = errors.New("нет права на эту операцию - обратитесь к администратору")
	// ErrUnknownKind - сервер не знает такого типа операции.
	ErrUnknownKind = errors.New("unknown operation kind")
	// ErrInvalidPayload - тело операции не разбирается или неполно.
	ErrInvalidPayload = errors.New("invalid operation payload")
)
