package model

import (
	"errors"
)

// Ошибки привязки штрихкодов.
var (
	// ErrBarcodeConflict - ШК уже привязан к ДРУГОМУ товару (один ШК → один товар).
	ErrBarcodeConflict = errors.New("barcode bound to another good")
	// ErrGoodNotFound - привязка к несуществующему товару (FK).
	ErrGoodNotFound = errors.New("good not found")
)

// Ошибки валидации ввода привязки ШК.
var (
	// ErrEmptyBarcode - не передан штрихкод.
	ErrEmptyBarcode = errors.New("barcode is required")
	// ErrEmptyGoodID - не передан товар для привязки.
	ErrEmptyGoodID = errors.New("good_id is required")
)
