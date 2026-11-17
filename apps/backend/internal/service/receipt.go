package service

import (
	"context"
	"errors"
	"time"

	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// ErrEmptyReceiptID - не указан документ приёмки.
//
// Остальные проверки переиспользуют ошибки, уже заведённые соседними сервисами
// (ErrEmptyWarehouse, ErrEmptyGoodID, ErrInvalidQuantity, ErrInvalidDate): заводить синонимы
// значило бы, что хендлеру придётся сопоставлять две ошибки на один смысл. ErrEmptyCell приёмке
// не нужна - пустая ячейка здесь не ошибка, а просьба подставить умолчание (P4-03).
var ErrEmptyReceiptID = errors.New("receipt id is required")

// ErrNoDefaultCell - у склада нет ячейки приёмки по умолчанию.
//
// Заводится вместе со складом (сидер при развёртывании, импорт ячеек при новом складе), поэтому
// её отсутствие - не рабочая ситуация кладовщика, а незавершённое развёртывание: приходовать
// «куда-нибудь» нельзя, и молчаливый выбор произвольной ячейки соврал бы про место хранения.
var ErrNoDefaultCell = errors.New("warehouse has no default cell")

// receiptRepo - зависимость сервиса от хранилища приёмки.
type receiptRepo interface {
	Create(ctx context.Context, id, warehouseID, supplierID, createdBy string, doc model.SupplierDoc) error
	AddLine(ctx context.Context, receiptID string, in model.ReceiptLineInput) error
	Post(ctx context.Context, receiptID string) (int, error)
	ByID(ctx context.Context, receiptID string) (model.Receipt, error)
	Lines(ctx context.Context, receiptID string) ([]model.ReceiptLine, error)
}

// receiptCellRepo - зависимость сервиса от справочника ячеек: нужна только дефолтная ячейка.
// Узкий интерфейс вместо всего CellRepository: приёмке не нужны ни апсерт, ни этикетки.
type receiptCellRepo interface {
	DefaultID(ctx context.Context, warehouseID string) (string, error)
}

// ReceiptService - приёмка: набор документа и его оприходование (P4-02, API - P4-03).
type ReceiptService struct {
	repo  receiptRepo
	cells receiptCellRepo
}

// NewReceiptService собирает сервис приёмки.
func NewReceiptService(repo receiptRepo, cells receiptCellRepo) *ReceiptService {
	return &ReceiptService{repo: repo, cells: cells}
}

// Start открывает документ приёмки с идентификатором, выданным устройством.
// Повтор с тем же id безопасен: документ уже есть, второй не заводится.
// [docNumber], [docDate] - накладная поставщика, обязательна (ADHOC-23).
func (s *ReceiptService) Start(ctx context.Context, id, warehouseID, supplierID, createdBy, docNumber, docDate string) error {
	if id == "" {
		return ErrEmptyReceiptID
	}
	if warehouseID == "" {
		return ErrEmptyWarehouse
	}
	doc, err := parseSupplierDoc(docNumber, docDate, time.Now())
	if err != nil {
		return err
	}
	return s.repo.Create(ctx, id, warehouseID, supplierID, createdBy, doc)
}

// AddLine добавляет строку в документ и возвращает ячейку, в которую она легла.
//
// Ячейку возвращаем, потому что её мог подставить сервер: кладовщик её не выбирал и обязан
// увидеть, куда именно принят товар, - иначе умолчание работает вслепую.
//
// Дата выпуска принимается в транспортном формате DD-MM-YYYY - том же, что у ввода остатков:
// кладовщик читает её с упаковки, и разные форматы на двух экранах приводили бы к ошибкам ввода.
func (s *ReceiptService) AddLine(ctx context.Context, receiptID, goodID, productionDate, cellID, loadUnitID string, qty decimal.Decimal) (string, error) {
	if receiptID == "" {
		return "", ErrEmptyReceiptID
	}
	if goodID == "" {
		return "", ErrEmptyGoodID
	}
	if !qty.IsPositive() {
		return "", ErrInvalidQuantity
	}
	iso, err := parseEntryDate(productionDate)
	if err != nil {
		return "", err
	}
	// Ячейка не указана - приходуем в дефолтную ячейку склада документа (решение заказчика:
	// кладовщик не выбирает место на приёмке). Домен ячейку требует явно и про умолчание не знает
	// (P4-02) - подставляет его этот слой, ровно здесь.
	if cellID == "" {
		cellID, err = s.defaultCell(ctx, receiptID)
		if err != nil {
			return "", err
		}
	}
	err = s.repo.AddLine(ctx, receiptID, model.ReceiptLineInput{
		GoodID:         goodID,
		ProductionDate: iso,
		CellID:         cellID,
		LoadUnitID:     loadUnitID,
		Qty:            qty,
	})
	if err != nil {
		return "", err
	}
	return cellID, nil
}

// defaultCell находит ячейку приёмки по умолчанию для склада, которому принадлежит документ.
//
// Склад берётся из шапки документа, а не из запроса: устройство про склад в строке не знает,
// а подставить чужой означало бы принять товар не на тот склад.
func (s *ReceiptService) defaultCell(ctx context.Context, receiptID string) (string, error) {
	rc, err := s.repo.ByID(ctx, receiptID)
	if err != nil {
		return "", err
	}
	cellID, err := s.cells.DefaultID(ctx, rc.WarehouseID)
	if errors.Is(err, repository.ErrNotFound) {
		return "", ErrNoDefaultCell
	}
	if err != nil {
		return "", err
	}
	return cellID, nil
}

// Post оприходует документ и возвращает число проведённых строк.
func (s *ReceiptService) Post(ctx context.Context, receiptID string) (int, error) {
	if receiptID == "" {
		return 0, ErrEmptyReceiptID
	}
	return s.repo.Post(ctx, receiptID)
}

// Get возвращает шапку документа и его строки - для показа кладовщику.
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
