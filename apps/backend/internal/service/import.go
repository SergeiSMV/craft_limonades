package service

import (
	"context"
	"fmt"
	"io"

	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/importer"
	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// Репозитории, нужные импорту (зависимости через интерфейсы). Все Upsert принимают Querier —
// чтобы весь импорт шёл в одной транзакции (всё-или-ничего).
type (
	groupRepo interface {
		Upsert(ctx context.Context, q repository.Querier, code, name string, parentID *string) (string, error)
	}
	supplierRepo interface {
		Upsert(ctx context.Context, q repository.Querier, name string) (string, error)
	}
	goodsUpsertRepo interface {
		Upsert(ctx context.Context, q repository.Querier, code, name, fullName, uom string, groupID, supplierID *string) (bool, error)
	}
	warehouseRepo interface {
		Upsert(ctx context.Context, q repository.Querier, code, name string) (string, error)
	}
	cellRepo interface {
		UpsertRack(ctx context.Context, q repository.Querier, warehouseID, code string, sideCard *bool) (string, bool, error)
		UpsertSetup(ctx context.Context, q repository.Querier, warehouseID string, rackID *string, c model.CellSetup) (bool, error)
		EnsureDefault(ctx context.Context, q repository.Querier, warehouseID string) (string, error)
	}
)

// ImportService — загрузка справочников из файлов: номенклатура (1С .xls) и ячейки склада (.xlsx).
type ImportService struct {
	pool       *pgxpool.Pool
	groups     groupRepo
	suppliers  supplierRepo
	goods      goodsUpsertRepo
	warehouses warehouseRepo
	cells      cellRepo
}

// NewImportService собирает сервис импорта.
func NewImportService(pool *pgxpool.Pool, groups groupRepo, suppliers supplierRepo, goods goodsUpsertRepo, warehouses warehouseRepo, cells cellRepo) *ImportService {
	return &ImportService{pool: pool, groups: groups, suppliers: suppliers, goods: goods, warehouses: warehouses, cells: cells}
}

// ImportReport — итог импорта номенклатуры (отдаётся клиенту).
type ImportReport struct {
	GoodsCreated int                 `json:"goods_created"` // новых товаров
	GoodsUpdated int                 `json:"goods_updated"` // обновлённых (повторный импорт)
	Groups       int                 `json:"groups"`        // затронуто групп
	Suppliers    int                 `json:"suppliers"`     // затронуто поставщиков
	Skipped      []importer.RowError `json:"skipped"`       // пропущенные строки с причинами
}

// ImportGoods разбирает .xls-выгрузку номенклатуры и загружает её в БД (группы→поставщики→товары)
// в одной транзакции. Проблемные строки не валят импорт — попадают в отчёт (Skipped).
func (s *ImportService) ImportGoods(ctx context.Context, r io.ReadSeeker) (*ImportReport, error) {
	parsed, err := importer.ParseGoods(r)
	if err != nil {
		return nil, err // не смогли прочитать файл/нет обязательной колонки — на уровень выше как 4xx
	}

	report := &ImportReport{Skipped: parsed.Errors}
	// Кэши в пределах импорта: не апсертить одну и ту же группу/поставщика на каждый товар.
	groupCache := map[string]string{}    // code группы → id
	supplierCache := map[string]string{} // имя поставщика → id

	txErr := repository.WithinTx(ctx, s.pool, func(q repository.Querier) error {
		for _, g := range parsed.Goods {
			if g.UOM == "" {
				report.Skipped = append(report.Skipped, importer.RowError{
					Message: fmt.Sprintf("товар %q без единицы измерения — пропущен", g.Code)})
				continue
			}

			// Путь групп сверху вниз: каждый узел апсертим с родителем-предыдущим; groupID = самый глубокий.
			var parentID, groupID *string
			for _, node := range g.GroupPath {
				id, ok := groupCache[node.Code]
				if !ok {
					id, err = s.groups.Upsert(ctx, q, node.Code, node.Name, parentID)
					if err != nil {
						return err
					}
					groupCache[node.Code] = id
					report.Groups++
				}
				cur := id
				parentID, groupID = &cur, &cur
			}

			// Поставщик (дедуп по имени).
			var supplierID *string
			if g.Supplier != "" {
				id, ok := supplierCache[g.Supplier]
				if !ok {
					id, err = s.suppliers.Upsert(ctx, q, g.Supplier)
					if err != nil {
						return err
					}
					supplierCache[g.Supplier] = id
					report.Suppliers++
				}
				cur := id
				supplierID = &cur
			}

			created, err := s.goods.Upsert(ctx, q, g.Code, g.Name, g.FullName, g.UOM, groupID, supplierID)
			if err != nil {
				return err
			}
			if created {
				report.GoodsCreated++
			} else {
				report.GoodsUpdated++
			}
		}
		return nil
	})
	if txErr != nil {
		return nil, txErr
	}
	return report, nil
}

// CellsImportReport — итог загрузки ячеек склада (отдаётся клиенту).
type CellsImportReport struct {
	Warehouse    string              `json:"warehouse"`     // code физического склада, в который загрузили
	CellsCreated int                 `json:"cells_created"` // новых ячеек
	CellsUpdated int                 `json:"cells_updated"` // обновлённых (повторная загрузка)
	RacksCreated int                 `json:"racks_created"` // новых стеллажей
	RacksUpdated int                 `json:"racks_updated"` // уже заведённых стеллажей из файла
	Skipped      []importer.RowError `json:"skipped"`       // пропущенные строки с причинами
}

// ImportCells загружает .xlsx ячеек в формате rack_labels (листы cells и racks) в один
// физический склад (warehouseCode/warehouseName — параметры, склада в файле нет) одной транзакцией.
//
// Как: сначала стеллажи листа racks — с признаком карточки; затем стеллажи, названные только в
// листе cells (без листа racks), — без изменения карточки; затем ячейки со ссылкой на стеллаж и
// настройками этикетки. Ячейки, которых нет в файле, не трогаются и не удаляются. Внутренний
// склад (основной/брак) здесь не участвует — это измерение остатка, не ячейки (ADR-0016).
// Проблемные строки не валят загрузку — попадают в отчёт (Skipped).
func (s *ImportService) ImportCells(ctx context.Context, r io.Reader, warehouseCode, warehouseName string) (*CellsImportReport, error) {
	parsed, err := importer.ParseCells(r)
	if err != nil {
		return nil, err // не смогли прочитать файл/нет обязательной колонки — на уровень выше как 4xx
	}

	report := &CellsImportReport{Warehouse: warehouseCode, Skipped: parsed.Errors}

	txErr := repository.WithinTx(ctx, s.pool, func(q repository.Querier) error {
		// Физический склад — один на файл: апсертим по code до ячеек, id используем для всех строк.
		warehouseID, err := s.warehouses.Upsert(ctx, q, warehouseCode, warehouseName)
		if err != nil {
			return err
		}
		rackIDs := map[string]string{}
		upsertRack := func(code string, sideCard *bool) error {
			id, created, err := s.cells.UpsertRack(ctx, q, warehouseID, code, sideCard)
			if err != nil {
				return err
			}
			rackIDs[code] = id
			if created {
				report.RacksCreated++
			} else {
				report.RacksUpdated++
			}
			return nil
		}
		for _, rk := range parsed.Racks {
			if err := upsertRack(rk.Code, &rk.SideCard); err != nil {
				return err
			}
		}
		for _, c := range parsed.Cells {
			if c.RackCode == "" || rackIDs[c.RackCode] != "" {
				continue
			}
			if err := upsertRack(c.RackCode, nil); err != nil {
				return err
			}
		}
		for _, c := range parsed.Cells {
			var rackID *string
			if id, ok := rackIDs[c.RackCode]; ok {
				rackID = &id
			}
			created, err := s.cells.UpsertSetup(ctx, q, warehouseID, rackID, model.CellSetup{
				Address: c.Address, IsFloor: c.IsFloor, LabelSmall: c.LabelSmall, LabelBarcode: c.LabelBarcode,
			})
			if err != nil {
				return err
			}
			if created {
				report.CellsCreated++
			} else {
				report.CellsUpdated++
			}
		}
		// Дефолтная ячейка приёмки — каждому складу, в том числе появившемуся этим импортом:
		// без неё приёмка на новом складе упёрлась бы в «некуда приходовать» (P4-03).
		// После цикла, а не до: если ячейка есть в самом файле, счётчики отчёта считают её строкой
		// файла, а не нашей добавкой — отчёт обязан сходиться с тем, что человек загрузил.
		if _, err := s.cells.EnsureDefault(ctx, q, warehouseID); err != nil {
			return err
		}
		return nil
	})
	if txErr != nil {
		return nil, txErr
	}
	return report, nil
}
