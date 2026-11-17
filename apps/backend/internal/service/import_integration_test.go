package service_test

import (
	"context"
	"os"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/repository"
	"craftwms/internal/service"
	"craftwms/internal/testutil"
)

const samplePath = "../importer/testdata/nomenclature_sample.xls"

func newImportSvc(pool *pgxpool.Pool) *service.ImportService {
	return service.NewImportService(pool,
		repository.NewNomenclatureGroupRepository(pool),
		repository.NewSupplierRepository(pool),
		repository.NewGoodsRepository(pool),
		repository.NewWarehouseRepository(pool),
		repository.NewCellRepository(pool))
}

func countRows(t *testing.T, pool *pgxpool.Pool, table string) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(context.Background(), "SELECT count(*) FROM "+table).Scan(&n); err != nil {
		t.Fatalf("count %s: %v", table, err)
	}
	return n
}

// TestImportGoods_realFile - полный импорт реальной выгрузки в живой Postgres:
// заводятся группы (дерево), поставщики (дедуп), товары; повторный импорт идемпотентен.
func TestImportGoods_realFile(t *testing.T) {
	pool := testutil.StartPostgres(t)
	svc := newImportSvc(pool)
	ctx := context.Background()

	// --- Первый импорт ---
	f, err := os.Open(samplePath)
	if err != nil {
		t.Fatalf("открыть образец: %v", err)
	}
	rep, err := svc.ImportGoods(ctx, f)
	_ = f.Close()
	if err != nil {
		t.Fatalf("ImportGoods: %v", err)
	}

	if rep.GoodsCreated != 15 || rep.GoodsUpdated != 0 {
		t.Errorf("отчёт: ожидалось created=15 updated=0, получено created=%d updated=%d", rep.GoodsCreated, rep.GoodsUpdated)
	}
	if len(rep.Skipped) != 0 {
		t.Errorf("ожидалось 0 пропущенных, получено %d: %+v", len(rep.Skipped), rep.Skipped)
	}
	// В БД: 3 группы (ветка), 2 поставщика, 15 товаров.
	if got := countRows(t, pool, "nomenclature_groups"); got != 3 {
		t.Errorf("групп: ожидалось 3, получено %d", got)
	}
	if got := countRows(t, pool, "suppliers"); got != 2 {
		t.Errorf("поставщиков: ожидалось 2, получено %d", got)
	}
	if got := countRows(t, pool, "goods"); got != 15 {
		t.Errorf("товаров: ожидалось 15, получено %d", got)
	}

	// Дерево групп: корень (parent_id IS NULL) один; самая глубокая группа (5046) ссылается на 2331.
	var roots int
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM nomenclature_groups WHERE parent_id IS NULL").Scan(&roots); err != nil {
		t.Fatal(err)
	}
	if roots != 1 {
		t.Errorf("корневых групп: ожидалось 1, получено %d", roots)
	}
	var parentCode string
	err = pool.QueryRow(ctx, `
		SELECT p.code FROM nomenclature_groups g
		JOIN nomenclature_groups p ON p.id = g.parent_id
		WHERE g.code = '5046'`).Scan(&parentCode)
	if err != nil {
		t.Fatalf("родитель группы 5046: %v", err)
	}
	if parentCode != "2331" {
		t.Errorf("родитель группы 5046: ожидалось 2331, получено %s", parentCode)
	}

	// Товар ссылается на самую глубокую группу (5046) и на поставщика.
	var goodGroupCode string
	var hasSupplier bool
	err = pool.QueryRow(ctx, `
		SELECT ng.code, (g.supplier_id IS NOT NULL)
		FROM goods g JOIN nomenclature_groups ng ON ng.id = g.group_id
		WHERE g.code = '16121'`).Scan(&goodGroupCode, &hasSupplier)
	if err != nil {
		t.Fatalf("товар 16121: %v", err)
	}
	if goodGroupCode != "5046" {
		t.Errorf("группа товара 16121: ожидалось 5046, получено %s", goodGroupCode)
	}
	if !hasSupplier {
		t.Errorf("у товара 16121 не проставлен поставщик")
	}

	// --- Повторный импорт того же файла: идемпотентность ---
	f2, err := os.Open(samplePath)
	if err != nil {
		t.Fatal(err)
	}
	rep2, err := svc.ImportGoods(ctx, f2)
	_ = f2.Close()
	if err != nil {
		t.Fatalf("повторный ImportGoods: %v", err)
	}
	if rep2.GoodsCreated != 0 || rep2.GoodsUpdated != 15 {
		t.Errorf("повтор: ожидалось created=0 updated=15, получено created=%d updated=%d", rep2.GoodsCreated, rep2.GoodsUpdated)
	}
	// Дублей в БД не появилось.
	if got := countRows(t, pool, "goods"); got != 15 {
		t.Errorf("после повтора товаров: ожидалось 15 (без дублей), получено %d", got)
	}
	if got := countRows(t, pool, "nomenclature_groups"); got != 3 {
		t.Errorf("после повтора групп: ожидалось 3, получено %d", got)
	}
	if got := countRows(t, pool, "suppliers"); got != 2 {
		t.Errorf("после повтора поставщиков: ожидалось 2, получено %d", got)
	}
}
