package service

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/shopspring/decimal"

	"craftwms/internal/repository"
)

// Форматы даты выпуска: транспортный (тело запроса) и внутренний ISO (для БД/партий).
const (
	dateLayoutIn  = "02-01-2006" // DD-MM-YYYY — как приходит в API
	dateLayoutISO = "2006-01-02" // YYYY-MM-DD — канон для Postgres/партий
)

// Ошибки ввода сессии остатков.
var (
	// ErrInvalidDate — дата выпуска не в формате DD-MM-YYYY либо несуществующая.
	ErrInvalidDate = errors.New("invalid production date (expected DD-MM-YYYY)")
	// ErrEmptyWarehouse — не передан склад для старта сессии.
	ErrEmptyWarehouse = errors.New("warehouse_id is required")
	// ErrEmptyCell — не передана ячейка в checkpoint.
	ErrEmptyCell = errors.New("cell_id is required")
)

// EntryLine — строка ввода (транспорт): дата в DD-MM-YYYY.
type EntryLine struct {
	GoodID         string
	ProductionDate string
	Qty            decimal.Decimal
}

// EntryBarcode — новая привязка ШК, пришедшая с checkpoint'ом.
type EntryBarcode struct {
	GoodID    string
	Barcode   string
	Symbology string
}

// stockEntryRepo — зависимость сервиса от репозитория сессии (интерфейс ради тестируемости).
type stockEntryRepo interface {
	Create(ctx context.Context, warehouseID, createdBy string) (string, error)
	Checkpoint(ctx context.Context, sessionID, cellID string, lines []repository.StockEntryLineInput, barcodes []repository.BarcodeBindInput) error
	Finalize(ctx context.Context, sessionID string) (int, error)
}

// StockEntryService — сессия ввода остатков: старт, checkpoint ячейки, финал. Валидирует ввод и
// приводит дату из DD-MM-YYYY в ISO; транзакционную атомарность держит репозиторий (P-FS-04).
type StockEntryService struct {
	repo stockEntryRepo
}

// NewStockEntryService собирает сервис из репозитория сессии.
func NewStockEntryService(repo stockEntryRepo) *StockEntryService {
	return &StockEntryService{repo: repo}
}

// Start открывает сессию ввода для склада; createdBy — id аутентифицированного кладовщика.
func (s *StockEntryService) Start(ctx context.Context, warehouseID, createdBy string) (string, error) {
	warehouseID = strings.TrimSpace(warehouseID)
	if warehouseID == "" {
		return "", ErrEmptyWarehouse
	}
	return s.repo.Create(ctx, warehouseID, createdBy)
}

// Checkpoint фиксирует ячейку: валидирует строки/привязки, парсит даты и передаёт в репозиторий.
func (s *StockEntryService) Checkpoint(ctx context.Context, sessionID, cellID string, lines []EntryLine, barcodes []EntryBarcode) error {
	cellID = strings.TrimSpace(cellID)
	if cellID == "" {
		return ErrEmptyCell
	}

	repoLines := make([]repository.StockEntryLineInput, 0, len(lines))
	for _, ln := range lines {
		goodID := strings.TrimSpace(ln.GoodID)
		if goodID == "" {
			return ErrEmptyGoodID
		}
		if ln.Qty.IsNegative() {
			return ErrInvalidQuantity
		}
		iso, err := parseEntryDate(ln.ProductionDate)
		if err != nil {
			return err
		}
		repoLines = append(repoLines, repository.StockEntryLineInput{GoodID: goodID, ProductionDate: iso, Qty: ln.Qty})
	}

	repoBarcodes := make([]repository.BarcodeBindInput, 0, len(barcodes))
	for _, b := range barcodes {
		goodID := strings.TrimSpace(b.GoodID)
		code := strings.TrimSpace(b.Barcode)
		if goodID == "" {
			return ErrEmptyGoodID
		}
		if code == "" {
			return ErrEmptyBarcode
		}
		repoBarcodes = append(repoBarcodes, repository.BarcodeBindInput{GoodID: goodID, Barcode: code, Symbology: strings.TrimSpace(b.Symbology)})
	}

	return s.repo.Checkpoint(ctx, sessionID, cellID, repoLines, repoBarcodes)
}

// Finalize переносит сессию в остатки и закрывает её; возвращает число записанных строк.
func (s *StockEntryService) Finalize(ctx context.Context, sessionID string) (int, error) {
	return s.repo.Finalize(ctx, sessionID)
}

// parseEntryDate разбирает дату выпуска DD-MM-YYYY и возвращает ISO YYYY-MM-DD (для БД/партий).
func parseEntryDate(s string) (string, error) {
	t, err := time.Parse(dateLayoutIn, strings.TrimSpace(s))
	if err != nil {
		return "", ErrInvalidDate
	}
	return t.Format(dateLayoutISO), nil
}
