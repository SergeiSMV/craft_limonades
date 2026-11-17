package model

import (
	"errors"
)

// Ошибки отгрузки возврата поставщику (ADHOC-31). Все - отказ по существу.
var (
	// ErrShipmentPosted - сеанс отгрузки с этим идентификатором уже проведён.
	ErrShipmentPosted = errors.New("return shipment already posted")
	// ErrEmptyShipment - в сеансе нет ни одной позиции.
	ErrEmptyShipment = errors.New("return shipment has no positions")
)

// ErrInvalidShipmentID - идентификатор сеанса отгрузки возврата не UUID (ADHOC-31).
var ErrInvalidShipmentID = errors.New("shipment id must be a UUID")

// Ошибки документа поставщика (ADHOC-23).
var (
	// ErrEmptyDocNumber - не указан номер накладной (без номера - «б/н»).
	ErrEmptyDocNumber = errors.New("supplier document number is required")
	// ErrDocNumberTooLong - номер накладной длиннее 50 знаков.
	ErrDocNumberTooLong = errors.New("supplier document number must be at most 50 characters")
	// ErrInvalidDocDate - дата накладной не указана, не в формате DD-MM-YYYY или в будущем.
	ErrInvalidDocDate = errors.New("supplier document date must be DD-MM-YYYY and not in the future")
)
