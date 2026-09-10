package service

import (
	"context"
	"errors"

	"github.com/shopspring/decimal"

	"craftwms/internal/model"
)

// ErrEmptyReceiptID — не указан документ приёмки.
//
// Остальные проверки переиспользуют ошибки, уже заведённые соседними сервисами
// (ErrEmptyWarehouse, ErrEmptyCell, ErrEmptyGoodID, ErrInvalidQuantity, ErrInvalidDate):
// заводить синонимы значило бы, что хендлеру придётся сопоставлять две ошибки на один смысл.
var ErrEmptyReceiptID = errors.New("receipt id is required")

// receiptRepo — зависимость сервиса от хранилища приёмки.
type receiptRepo interface {
	Create(ctx context.Context, id, warehouseID, supplierID, createdBy string) error
	AddLine(ctx context.Context, receiptID string, in model.ReceiptLineInput) error
	Post(ctx context.Context, receiptID string) (int, error)
	ByID(ctx context.Context, receiptID string) (model.Receipt, error)
	Lines(ctx context.Context, receiptID string) ([]model.ReceiptLine, error)
}

// ReceiptService — приёмка: набор документа и его оприходование (P4-02).
type ReceiptService struct {
	repo receiptRepo
}

// NewReceiptService собирает сервис приёмки.
func NewReceiptService(repo receiptRepo) *ReceiptService {
	return &ReceiptService{repo: repo}
}

// Start открывает документ приёмки с идентификатором, выданным устройством.
// Повтор с тем же id безопасен: документ уже есть, второй не заводится.
func (s *ReceiptService) Start(ctx context.Context, id, warehouseID, supplierID, createdBy string) error {
	if id == "" {
		return ErrEmptyReceiptID
	}
	if warehouseID == "" {
		return ErrEmptyWarehouse
	}
	return s.repo.Create(ctx, id, warehouseID, supplierID, createdBy)
}

// AddLine добавляет строку в документ. Дата выпуска принимается в транспортном формате
// DD-MM-YYYY — том же, что у ввода остатков: кладовщик читает её с упаковки, и разные форматы
// на двух экранах приводили бы к ошибкам ввода.
func (s *ReceiptService) AddLine(ctx context.Context, receiptID, goodID, productionDate, cellID, loadUnitID string, qty decimal.Decimal) error {
	if receiptID == "" {
		return ErrEmptyReceiptID
	}
	if goodID == "" {
		return ErrEmptyGoodID
	}
	if cellID == "" {
		return ErrEmptyCell
	}
	if !qty.IsPositive() {
		return ErrInvalidQuantity
	}
	iso, err := parseEntryDate(productionDate)
	if err != nil {
		return err
	}
	return s.repo.AddLine(ctx, receiptID, model.ReceiptLineInput{
		GoodID:         goodID,
		ProductionDate: iso,
		CellID:         cellID,
		LoadUnitID:     loadUnitID,
		Qty:            qty,
	})
}

// Post оприходует документ и возвращает число проведённых строк.
func (s *ReceiptService) Post(ctx context.Context, receiptID string) (int, error) {
	if receiptID == "" {
		return 0, ErrEmptyReceiptID
	}
	return s.repo.Post(ctx, receiptID)
}

// Get возвращает шапку документа и его строки — для показа кладовщику.
func (s *ReceiptService) Get(ctx context.Context, receiptID string) (model.Receipt, []model.ReceiptLine, error) {
	if receiptID == "" {
		return model.Receipt{}, nil, ErrEmptyReceiptID
	}
	rc, err := s.repo.ByID(ctx, receiptID)
	if err != nil {
		return model.Receipt{}, nil, err
	}
	lines, err := s.repo.Lines(ctx, receiptID)
	if err != nil {
		return model.Receipt{}, nil, err
	}
	return rc, lines, nil
}
