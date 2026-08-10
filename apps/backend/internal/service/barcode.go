package service

import (
	"context"
	"errors"
	"strings"

	"craftwms/internal/model"
)

// Ошибки валидации ввода привязки ШК.
var (
	// ErrEmptyBarcode — не передан штрихкод.
	ErrEmptyBarcode = errors.New("barcode is required")
	// ErrEmptyGoodID — не передан товар для привязки.
	ErrEmptyGoodID = errors.New("good_id is required")
)

// barcodeRepo — зависимость сервиса от хранилища ШК (интерфейс ради тестируемости).
type barcodeRepo interface {
	GetGoodByBarcode(ctx context.Context, code string) (model.Good, error)
	Bind(ctx context.Context, goodID, barcode, symbology string) error
}

// BarcodeService — резолв товара по ШК и привязка ШК к товару (ввод остатков P-FastStart).
// Валидирует ввод; доменные ошибки хранилища (ErrNotFound/ErrBarcodeConflict/ErrGoodNotFound)
// проходят как есть — хендлер маппит их в HTTP-коды.
type BarcodeService struct {
	repo barcodeRepo
}

// NewBarcodeService собирает сервис из репозитория ШК.
func NewBarcodeService(repo barcodeRepo) *BarcodeService {
	return &BarcodeService{repo: repo}
}

// ResolveGood — товар по ШК; нет привязки → repository.ErrNotFound.
func (s *BarcodeService) ResolveGood(ctx context.Context, code string) (model.Good, error) {
	code = strings.TrimSpace(code)
	if code == "" {
		return model.Good{}, ErrEmptyBarcode
	}
	return s.repo.GetGoodByBarcode(ctx, code)
}

// Bind — привязать ШК к товару (аддитивно, идемпотентно). Пустые good_id/barcode отклоняются.
func (s *BarcodeService) Bind(ctx context.Context, goodID, barcode, symbology string) error {
	goodID = strings.TrimSpace(goodID)
	barcode = strings.TrimSpace(barcode)
	symbology = strings.TrimSpace(symbology)
	if goodID == "" {
		return ErrEmptyGoodID
	}
	if barcode == "" {
		return ErrEmptyBarcode
	}
	return s.repo.Bind(ctx, goodID, barcode, symbology)
}
