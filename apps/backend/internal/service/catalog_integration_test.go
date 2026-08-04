package service_test

import (
	"context"
	"errors"
	"os"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/internal/service"
	"craftwms/internal/testutil"
)

func newCatalogSvc(pool *pgxpool.Pool) *service.CatalogService {
	return service.NewCatalogService(
		repository.NewGoodsRepository(pool),
		repository.NewNomenclatureGroupRepository(pool),
		repository.NewSupplierRepository(pool),
		repository.NewCellRepository(pool),
		repository.NewStockRepository(pool),
	)
}

// seedCatalog наполняет БД справочниками через импорт (номенклатура + ячейки) — как в проде.
func seedCatalog(t *testing.T, pool *pgxpool.Pool) {
	t.Helper()
	ctx := context.Background()
	imp := newImportSvc(pool)

	fg, err := os.Open(samplePath)
	if err != nil {
		t.Fatalf("открыть номенклатуру: %v", err)
	}
	defer func() { _ = fg.Close() }()
	if _, err := imp.ImportGoods(ctx, fg); err != nil {
		t.Fatalf("ImportGoods: %v", err)
	}

	fc, err := os.Open(cellsSamplePath)
	if err != nil {
		t.Fatalf("открыть ячейки: %v", err)
	}
	defer func() { _ = fc.Close() }()
	if _, err := imp.ImportCells(ctx, fc, "SHB", "Шабулина"); err != nil {
		t.Fatalf("ImportCells: %v", err)
	}
}

// TestCatalog_goodsCellsSuppliers — чтение справочников через CatalogService: списки, поиск, фильтры, пагинация.
func TestCatalog_goodsCellsSuppliers(t *testing.T) {
	pool := testutil.StartPostgres(t)
	seedCatalog(t, pool)
	cat := newCatalogSvc(pool)
	ctx := context.Background()

	// --- Товары: всего 15, пагинация, поиск, фильтр по группе ---
	all, err := cat.ListGoods(ctx, service.GoodsQuery{})
	if err != nil {
		t.Fatalf("ListGoods: %v", err)
	}
	if all.Total != 15 || len(all.Items) != 15 {
		t.Errorf("товары: ожидалось total=15/items=15, получено total=%d/items=%d", all.Total, len(all.Items))
	}

	pageSized, err := cat.ListGoods(ctx, service.GoodsQuery{Limit: 5})
	if err != nil {
		t.Fatal(err)
	}
	if pageSized.Total != 15 || len(pageSized.Items) != 5 || pageSized.Limit != 5 {
		t.Errorf("пагинация: ожидалось total=15/items=5/limit=5, получено total=%d/items=%d/limit=%d",
			pageSized.Total, len(pageSized.Items), pageSized.Limit)
	}

	byCode, err := cat.ListGoods(ctx, service.GoodsQuery{Query: "16121"})
	if err != nil {
		t.Fatal(err)
	}
	if byCode.Total != 1 {
		t.Errorf("поиск по коду 16121: ожидалось 1, получено %d", byCode.Total)
	}

	// Фильтр по группе 5046 (самая глубокая): все товары ветки в ней.
	var groupID string
	if err := pool.QueryRow(ctx, "SELECT id::text FROM nomenclature_groups WHERE code='5046'").Scan(&groupID); err != nil {
		t.Fatal(err)
	}
	byGroup, err := cat.ListGoods(ctx, service.GoodsQuery{GroupID: &groupID})
	if err != nil {
		t.Fatal(err)
	}
	if byGroup.Total != 15 {
		t.Errorf("фильтр по группе 5046: ожидалось 15, получено %d", byGroup.Total)
	}
	// Присоединённые имена группы/поставщика проставлены.
	if byGroup.Items[0].GroupName == nil || byGroup.Items[0].SupplierName == nil {
		t.Errorf("ожидались присоединённые group_name/supplier_name, получено %+v", byGroup.Items[0])
	}

	// --- GetGood: существующий id → ок; случайный → ErrNotFound ---
	got, err := cat.GetGood(ctx, all.Items[0].ID)
	if err != nil {
		t.Fatalf("GetGood: %v", err)
	}
	if got.ID != all.Items[0].ID {
		t.Errorf("GetGood вернул не тот id: %s != %s", got.ID, all.Items[0].ID)
	}
	if _, err := cat.GetGood(ctx, "00000000-0000-0000-0000-000000000000"); !errors.Is(err, repository.ErrNotFound) {
		t.Errorf("GetGood(случайный): ожидался ErrNotFound, получено %v", err)
	}

	// --- Группы / поставщики ---
	groups, err := cat.ListGroups(ctx)
	if err != nil || len(groups) != 3 {
		t.Errorf("группы: ожидалось 3, получено %d (err=%v)", len(groups), err)
	}
	suppliers, err := cat.ListSuppliers(ctx, "")
	if err != nil || len(suppliers) != 2 {
		t.Errorf("поставщики: ожидалось 2, получено %d (err=%v)", len(suppliers), err)
	}

	// --- Ячейки: всего 125, фильтр по напольным, поиск по адресу ---
	cellsAll, err := cat.ListCells(ctx, service.CellsQuery{})
	if err != nil {
		t.Fatal(err)
	}
	if cellsAll.Total != 125 {
		t.Errorf("ячейки: ожидалось 125, получено %d", cellsAll.Total)
	}
	floorTrue := true
	floors, err := cat.ListCells(ctx, service.CellsQuery{IsFloor: &floorTrue})
	if err != nil {
		t.Fatal(err)
	}
	if floors.Total != 25 {
		t.Errorf("напольные ячейки: ожидалось 25, получено %d", floors.Total)
	}
	byAddr, err := cat.ListCells(ctx, service.CellsQuery{Query: "M1-1-1-1"})
	if err != nil {
		t.Fatal(err)
	}
	if byAddr.Total != 1 || byAddr.Items[0].Address != "M1-1-1-1" {
		t.Errorf("поиск ячейки M1-1-1-1: ожидалась 1, получено total=%d", byAddr.Total)
	}
}

// TestCatalog_stock — остатки в товарном разрезе: адрес ячейки, дата партии, точное decimal-количество.
func TestCatalog_stock(t *testing.T) {
	pool := testutil.StartPostgres(t)
	seedCatalog(t, pool)
	cat := newCatalogSvc(pool)
	ctx := context.Background()

	// Берём реальный товар и ячейку из наполненных справочников.
	var goodID, cellID, cellAddr string
	if err := pool.QueryRow(ctx, "SELECT id::text FROM goods WHERE code='16121'").Scan(&goodID); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, "SELECT id::text, address FROM cells WHERE address='M1-1-1-1'").Scan(&cellID, &cellAddr); err != nil {
		t.Fatal(err)
	}
	// Партия товара + остаток 10.5 кг (проверяем точность decimal).
	var batchID string
	if err := pool.QueryRow(ctx,
		"INSERT INTO batches (good_id, production_date) VALUES ($1::uuid, '2026-01-15') RETURNING id::text",
		goodID).Scan(&batchID); err != nil {
		t.Fatal(err)
	}
	stockRepo := repository.NewStockRepository(pool)
	if err := stockRepo.Add(ctx, model.StockKey{CellID: cellID, GoodID: goodID, BatchID: batchID},
		decimal.RequireFromString("10.5")); err != nil {
		t.Fatalf("Add stock: %v", err)
	}

	// «Где лежит товар» — good_id фильтр.
	page, err := cat.ListStock(ctx, service.StockQuery{GoodID: &goodID})
	if err != nil {
		t.Fatalf("ListStock: %v", err)
	}
	if page.Total != 1 || len(page.Items) != 1 {
		t.Fatalf("остатки товара: ожидалось 1, получено total=%d", page.Total)
	}
	it := page.Items[0]
	if it.CellAddress != cellAddr || it.ProductionDate != "2026-01-15" || !it.Qty.Equal(decimal.RequireFromString("10.5")) {
		t.Errorf("остаток: ожидалось {addr=%s, date=2026-01-15, qty=10.5}, получено {addr=%s, date=%s, qty=%s}",
			cellAddr, it.CellAddress, it.ProductionDate, it.Qty)
	}

	// Пустой результат — непустой слайс (в JSON []): товар без остатка.
	empty, err := cat.ListStock(ctx, service.StockQuery{GoodID: strptr("00000000-0000-0000-0000-000000000000")})
	if err != nil {
		t.Fatal(err)
	}
	if empty.Items == nil {
		t.Error("ожидался непустой слайс для пустого результата (JSON []), получен nil")
	}
	if empty.Total != 0 {
		t.Errorf("пустой остаток: ожидалось total=0, получено %d", empty.Total)
	}
}

func strptr(s string) *string { return &s }
