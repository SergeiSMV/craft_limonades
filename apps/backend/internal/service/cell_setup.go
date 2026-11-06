package service

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/importer"
	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// Ошибки изменения настроек ячеек — 400 у хендлера.
var (
	ErrNoCellsSelected = errors.New("не выбраны ячейки")
	ErrEmptyCellsPatch = errors.New("нечего менять: не задана ни одна галочка")
	ErrTooManyCells    = errors.New("слишком много ячеек за один раз")
	ErrInvalidCellIDs  = errors.New("id ячейки должен быть UUID")
	// ErrInvalidFloorAddress — адрес напольной ячейки не вида «D-Н-П» (ADHOC-61).
	ErrInvalidFloorAddress = errors.New("адрес напольной ячейки - стеллаж и «-Н-П», например «D-Н-П»")
)

// floorAddressRe — адрес напольной ячейки после нормализации: сегменты букв и цифр через дефис,
// последние два — «Н-П» кириллицей. Стеллаж — хоть один сегмент перед ними («D», «M1»).
var floorAddressRe = regexp.MustCompile(`^[0-9A-ZА-ЯЁ]+(?:-[0-9A-ZА-ЯЁ]+)*-Н-П$`)

// maxCellsPatch — потолок ячеек в одном изменении: склад целиком (сотни ячеек) с запасом,
// но не бесконечный массив в одном запросе.
const maxCellsPatch = 5000

// cellSetupRepo — чтение и правка раскладки ячеек склада для страницы «Ячейки».
type cellSetupRepo interface {
	Setup(ctx context.Context, warehouseID string) ([]model.CellSetup, []model.Rack, error)
	UpdateSettings(ctx context.Context, q repository.Querier, warehouseID string, p model.CellSettingsPatch) (model.CellSettingsResult, error)
	CreateFloorCell(ctx context.Context, q repository.Querier, warehouseID, address string) (string, error)
	RenameFloorCell(ctx context.Context, q repository.Querier, warehouseID, cellID, address string) error
	DeleteFloorCell(ctx context.Context, q repository.Querier, warehouseID, cellID string) error
}

// CellSetupService — страница «Ячейки» портала (ADHOC-57): список ячеек со стеллажами и
// настройками этикеток, массовая правка галочек и выгрузка в файл формата rack_labels.
type CellSetupService struct {
	pool       *pgxpool.Pool
	warehouses warehouseCodeRepo
	cells      cellSetupRepo
}

// NewCellSetupService собирает сервис страницы «Ячейки».
func NewCellSetupService(pool *pgxpool.Pool, warehouses warehouseCodeRepo, cells cellSetupRepo) *CellSetupService {
	return &CellSetupService{pool: pool, warehouses: warehouses, cells: cells}
}

// Setup возвращает ячейки склада и его стеллажи. Неизвестный склад — repository.ErrNotFound.
// Ячейки — в натуральном порядке адреса (B-1-2-1 раньше B-1-10-1), стеллажи — по коду так же.
func (s *CellSetupService) Setup(ctx context.Context, warehouseCode string) (*model.CellsSetup, error) {
	whID, err := s.warehouses.IDByCode(ctx, warehouseCode)
	if err != nil {
		return nil, err
	}
	cells, racks, err := s.cells.Setup(ctx, whID)
	if err != nil {
		return nil, err
	}
	sort.Slice(cells, func(i, j int) bool { return naturalLess(cells[i].Address, cells[j].Address) })
	sort.Slice(racks, func(i, j int) bool { return naturalLess(racks[i].Code, racks[j].Code) })
	return &model.CellsSetup{Warehouse: warehouseCode, Cells: cells, Racks: racks}, nil
}

// UpdateSettings меняет галочки у выбранных ячеек склада одной транзакцией.
//
// Проверки до записи: есть ячейки и хоть одна галочка, id — UUID, не больше maxCellsPatch.
// Повторы id схлопываются: портал может прислать ячейку дважды, а репозиторий сверяет число
// найденных с числом присланных. Чужие или несуществующие ячейки — repository.ErrForeignCells.
func (s *CellSetupService) UpdateSettings(ctx context.Context, warehouseCode string, p model.CellSettingsPatch) (model.CellSettingsResult, error) {
	var res model.CellSettingsResult
	if len(p.CellIDs) == 0 {
		return res, ErrNoCellsSelected
	}
	if p.Empty() {
		return res, ErrEmptyCellsPatch
	}
	ids := make([]string, 0, len(p.CellIDs))
	seen := map[string]bool{}
	for _, id := range p.CellIDs {
		if _, err := uuid.Parse(id); err != nil {
			return res, ErrInvalidCellIDs
		}
		if !seen[id] {
			seen[id] = true
			ids = append(ids, id)
		}
	}
	if len(ids) > maxCellsPatch {
		return res, ErrTooManyCells
	}
	p.CellIDs = ids

	whID, err := s.warehouses.IDByCode(ctx, warehouseCode)
	if err != nil {
		return res, err
	}
	err = repository.WithinTx(ctx, s.pool, func(q repository.Querier) error {
		var txErr error
		res, txErr = s.cells.UpdateSettings(ctx, q, whID, p)
		return txErr
	})
	return res, err
}

// ExportXLSX выгружает ячейки и стеллажи склада в .xlsx формата rack_labels; возвращает файл и
// его имя («cells-SHB.xlsx»). Порядок — как на странице.
func (s *CellSetupService) ExportXLSX(ctx context.Context, warehouseCode string) ([]byte, string, error) {
	setup, err := s.Setup(ctx, warehouseCode)
	if err != nil {
		return nil, "", err
	}
	cells := make([]importer.ExportCell, 0, len(setup.Cells))
	for _, c := range setup.Cells {
		rack := ""
		if c.RackCode != nil {
			rack = *c.RackCode
		}
		cells = append(cells, importer.ExportCell{
			Address: c.Address, RackCode: rack,
			LabelSmall: c.LabelSmall, IsFloor: c.IsFloor, LabelBarcode: c.LabelBarcode, SideCard: c.SideCard,
		})
	}
	// Карточка стеллажа на листе racks — есть ли у него ячейки с галочкой (для rack_labels).
	withCard := map[string]bool{}
	for _, c := range setup.Cells {
		if c.SideCard && c.RackID != nil {
			withCard[*c.RackID] = true
		}
	}
	racks := make([]importer.RackRow, 0, len(setup.Racks))
	for _, r := range setup.Racks {
		racks = append(racks, importer.RackRow{Code: r.Code, SideCard: withCard[r.ID]})
	}
	data, err := importer.BuildCellsXLSX(cells, racks)
	if err != nil {
		return nil, "", err
	}
	return data, fmt.Sprintf("cells-%s.xlsx", warehouseCode), nil
}

// NormalizeFloorAddress приводит адрес напольной ячейки к виду справочника: без пробелов по краям,
// заглавными, «Н» в окончании — кириллицей (латинскую H на клавиатуре не отличить). Неверный
// адрес — ErrInvalidFloorAddress.
func NormalizeFloorAddress(raw string) (string, error) {
	a := strings.ToUpper(strings.TrimSpace(raw))
	if strings.HasSuffix(a, "-H-П") {
		a = strings.TrimSuffix(a, "-H-П") + model.FloorStorageSuffix
	}
	if !floorAddressRe.MatchString(a) {
		return "", ErrInvalidFloorAddress
	}
	return a, nil
}

// CreateFloorCell заводит напольную ячейку склада (ADHOC-61). Адрес занят активной ячейкой —
// repository.ErrCellExists; удалённая с тем же адресом возвращается в работу.
func (s *CellSetupService) CreateFloorCell(ctx context.Context, warehouseCode string, in model.FloorCellInput) (model.FloorCell, error) {
	address, err := NormalizeFloorAddress(in.Address)
	if err != nil {
		return model.FloorCell{}, err
	}
	whID, err := s.warehouses.IDByCode(ctx, warehouseCode)
	if err != nil {
		return model.FloorCell{}, err
	}
	var id string
	err = repository.WithinTx(ctx, s.pool, func(q repository.Querier) error {
		var txErr error
		id, txErr = s.cells.CreateFloorCell(ctx, q, whID, address)
		return txErr
	})
	if err != nil {
		return model.FloorCell{}, err
	}
	return model.FloorCell{ID: id, Address: address}, nil
}

// RenameFloorCell меняет адрес напольной ячейки. Ячейку стеллажа или приёмки так не
// переименовать — repository.ErrNotFound.
func (s *CellSetupService) RenameFloorCell(ctx context.Context, warehouseCode, cellID string, in model.FloorCellInput) (model.FloorCell, error) {
	if _, err := uuid.Parse(cellID); err != nil {
		return model.FloorCell{}, ErrInvalidCellIDs
	}
	address, err := NormalizeFloorAddress(in.Address)
	if err != nil {
		return model.FloorCell{}, err
	}
	whID, err := s.warehouses.IDByCode(ctx, warehouseCode)
	if err != nil {
		return model.FloorCell{}, err
	}
	err = repository.WithinTx(ctx, s.pool, func(q repository.Querier) error {
		return s.cells.RenameFloorCell(ctx, q, whID, cellID, address)
	})
	if err != nil {
		return model.FloorCell{}, err
	}
	return model.FloorCell{ID: cellID, Address: address}, nil
}

// DeleteFloorCell убирает пустую напольную ячейку. Есть товар или короба —
// repository.ErrCellNotEmpty.
func (s *CellSetupService) DeleteFloorCell(ctx context.Context, warehouseCode, cellID string) error {
	if _, err := uuid.Parse(cellID); err != nil {
		return ErrInvalidCellIDs
	}
	whID, err := s.warehouses.IDByCode(ctx, warehouseCode)
	if err != nil {
		return err
	}
	return repository.WithinTx(ctx, s.pool, func(q repository.Querier) error {
		return s.cells.DeleteFloorCell(ctx, q, whID, cellID)
	})
}
