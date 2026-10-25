package service

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
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
	// ErrInvalidSessionID — клиент прислал session_id, не являющийся UUID.
	ErrInvalidSessionID = errors.New("session_id must be a UUID")
)

// EntryLine — строка ввода (транспорт): дата в DD-MM-YYYY.
type EntryLine struct {
	GoodID         string
	ProductionDate string
	Qty            decimal.Decimal
	// LoadUnitID — короб ячейки, в котором лежит товар (ADHOC-46); пусто — россыпь.
	LoadUnitID string
	// Marks — марки ЧЗ строки (ADHOC-46).
	Marks []EntryMark
}

// EntryMark — марка ЧЗ строки ввода (ADHOC-46).
type EntryMark struct {
	CIS           string
	AggregateCode string // упаковка ЧЗ той же ячейки; пусто — сама по себе
	Discrepancy   string // расхождение со скана; пусто — нет
}

// EntryLoadUnit — короб, заведённый в ячейке прохода (ADHOC-46): свой с QR или короб ЧЗ.
type EntryLoadUnit struct {
	ID     string
	Kind   string
	CZCode string // `00`+SSCC короба ЧЗ; пусто — свой короб с QR
}

// EntryGroup — групповая упаковка ЧЗ ячейки прохода (ADHOC-46).
type EntryGroup struct {
	Code       string
	ParentCode string
}

// EntryCell — ячейка прохода в checkpoint'е (транспорт).
type EntryCell struct {
	CellID    string
	Lines     []EntryLine
	LoadUnits []EntryLoadUnit
	CZGroups  []EntryGroup
	Barcodes  []EntryBarcode
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
	CreateWithID(ctx context.Context, sessionID, warehouseID, createdBy string) (string, error)
	Checkpoint(ctx context.Context, sessionID string, in repository.StockEntryCellInput) error
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
//
// sessionID — идентификатор, выданный устройством (P2-05). Пустой означает «сервер, выдай сам»:
// так ходит APK, собранная до P2-05, и ломать её незачем — старт по-прежнему работает, просто
// без офлайн-адресации.
//
// Непустой id идемпотентен: повторный старт той же сессии возвращает её же. Это нужно ровно
// потому, что старт едет из очереди и повторяется, пока не подтверждён.
func (s *StockEntryService) Start(ctx context.Context, sessionID, warehouseID, createdBy string) (string, error) {
	warehouseID = strings.TrimSpace(warehouseID)
	if warehouseID == "" {
		return "", ErrEmptyWarehouse
	}
	sessionID = strings.TrimSpace(sessionID)
	if sessionID == "" {
		return s.repo.Create(ctx, warehouseID, createdBy)
	}
	// Проверяем формат до похода в БД: иначе кривой id уедет в приведение ::uuid и вернётся
	// 500-й внутренней ошибкой вместо внятного «это не UUID».
	if _, err := uuid.Parse(sessionID); err != nil {
		return "", ErrInvalidSessionID
	}
	return s.repo.CreateWithID(ctx, sessionID, warehouseID, createdBy)
}

// Checkpoint фиксирует ячейку: валидирует строки, короба, упаковки и марки, привязки, парсит
// даты и передаёт в репозиторий.
//
// Форма данных ЧЗ (коды, вложенность упаковок, марка короба ЧЗ — в строке этого короба)
// проверяется тем же czIntake, что у приёмки (ADHOC-46): отказ до транзакции, а не нарушение
// ключа на середине вставки. Строка в коробе ссылается на короб той же ячейки.
func (s *StockEntryService) Checkpoint(ctx context.Context, sessionID string, cell EntryCell) error {
	in := repository.StockEntryCellInput{CellID: strings.TrimSpace(cell.CellID)}
	if in.CellID == "" {
		return ErrEmptyCell
	}

	boxes := map[string]bool{}
	for _, lu := range cell.LoadUnits {
		id := strings.TrimSpace(lu.ID)
		if !isUUID(id) {
			return ErrInvalidLoadUnitID
		}
		kind := strings.TrimSpace(lu.Kind)
		if kind == "" {
			kind = model.LoadUnitBox
		}
		if kind != model.LoadUnitBox && kind != model.LoadUnitPallet {
			return ErrInvalidLoadUnitKind
		}
		boxes[id] = true
		in.LoadUnits = append(in.LoadUnits, repository.LoadUnitInput{
			ID: id, Kind: kind, CZCode: strings.TrimSpace(lu.CZCode),
		})
	}
	groups := make([]czGroupPayload, len(cell.CZGroups))
	for i, g := range cell.CZGroups {
		groups[i] = czGroupPayload(g)
	}
	cz, err := newCZIntake(in.LoadUnits, groups)
	if err != nil {
		return err
	}
	in.CZGroups = cz.groups

	for _, ln := range cell.Lines {
		goodID := strings.TrimSpace(ln.GoodID)
		if goodID == "" {
			return ErrEmptyGoodID
		}
		luID := strings.TrimSpace(ln.LoadUnitID)
		if luID != "" && !boxes[luID] {
			return ErrInvalidLoadUnitID
		}
		// Ноль россыпью — «здесь этого нет» (SET грани), а пустая строка короба смысла не имеет.
		if ln.Qty.IsNegative() || (luID != "" && !ln.Qty.IsPositive()) {
			return ErrInvalidQuantity
		}
		iso, err := parseEntryDate(ln.ProductionDate)
		if err != nil {
			return err
		}
		marks := make([]czMarkPayload, len(ln.Marks))
		for i, m := range ln.Marks {
			marks[i] = czMarkPayload(m)
		}
		lineMarks, err := cz.marks(marks, luID, ln.Qty)
		if err != nil {
			return err
		}
		in.Lines = append(in.Lines, repository.StockEntryLineInput{
			GoodID: goodID, ProductionDate: iso, Qty: ln.Qty, LoadUnitID: luID, Marks: lineMarks,
		})
	}

	for _, b := range cell.Barcodes {
		goodID := strings.TrimSpace(b.GoodID)
		code := strings.TrimSpace(b.Barcode)
		if goodID == "" {
			return ErrEmptyGoodID
		}
		if code == "" {
			return ErrEmptyBarcode
		}
		in.Barcodes = append(in.Barcodes, repository.BarcodeBindInput{GoodID: goodID, Barcode: code, Symbology: strings.TrimSpace(b.Symbology)})
	}

	return s.repo.Checkpoint(ctx, sessionID, in)
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
