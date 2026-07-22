package repository_test

import (
	"context"
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/golang-migrate/migrate/v4"
	_ "github.com/golang-migrate/migrate/v4/database/pgx/v5" // драйвер pgx5:// для миграций
	"github.com/golang-migrate/migrate/v4/source/iofs"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/shopspring/decimal"
	"github.com/testcontainers/testcontainers-go"
	tcpostgres "github.com/testcontainers/testcontainers-go/modules/postgres"
	"github.com/testcontainers/testcontainers-go/wait"

	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/migrations"
)

// stockFixture — поднятый Postgres со схемой и минимальным справочником для тестов остатка.
type stockFixture struct {
	pool         *pgxpool.Pool
	cellA, cellB string
	good, batch  string
}

// setupStock поднимает одноразовый Postgres (testcontainers), накатывает миграции и
// заводит склад + две ячейки + товар + партию. Пропускается, если Docker недоступен
// (локально без colima) — в CI Docker есть, тест отработает.
func setupStock(t *testing.T) *stockFixture {
	t.Helper()
	testcontainers.SkipIfProviderIsNotHealthy(t) // нет Docker → t.Skip, а не падение

	ctx := context.Background()
	ctr, err := tcpostgres.Run(ctx, "postgres:16-alpine",
		tcpostgres.WithDatabase("wms"),
		tcpostgres.WithUsername("wms"),
		tcpostgres.WithPassword("wms"),
		testcontainers.WithWaitStrategy(
			wait.ForLog("database system is ready to accept connections").
				WithOccurrence(2).WithStartupTimeout(60*time.Second)),
	)
	testcontainers.CleanupContainer(t, ctr) // гарантированно погасит контейнер после теста
	if err != nil {
		t.Fatalf("запуск postgres-контейнера: %v", err)
	}

	dsn, err := ctr.ConnectionString(ctx, "sslmode=disable")
	if err != nil {
		t.Fatalf("connection string: %v", err)
	}

	// Миграции — той же встроенной ФС, что и прод (migrations.FS); pgx5:// как в cmd/migrate.
	src, err := iofs.New(migrations.FS, ".")
	if err != nil {
		t.Fatalf("источник миграций: %v", err)
	}
	m, err := migrate.NewWithSourceInstance("iofs", src, strings.Replace(dsn, "postgres://", "pgx5://", 1))
	if err != nil {
		t.Fatalf("init migrate: %v", err)
	}
	if err := m.Up(); err != nil {
		t.Fatalf("migrate up: %v", err)
	}

	pool, err := repository.NewPool(ctx, dsn)
	if err != nil {
		t.Fatalf("пул: %v", err)
	}
	t.Cleanup(pool.Close)

	// Минимальный справочник: склад → 2 ячейки, товар, партия.
	fx := &stockFixture{pool: pool}
	var wh string
	mustScan(t, pool, `INSERT INTO warehouses (code, name) VALUES ('WH1','test') RETURNING id::text`, &wh)
	mustScan(t, pool, `INSERT INTO cells (warehouse_id, address) VALUES ($1::uuid,'A') RETURNING id::text`, &fx.cellA, wh)
	mustScan(t, pool, `INSERT INTO cells (warehouse_id, address) VALUES ($1::uuid,'B') RETURNING id::text`, &fx.cellB, wh)
	mustScan(t, pool, `INSERT INTO goods (name, uom) VALUES ('Товар','шт') RETURNING id::text`, &fx.good)
	mustScan(t, pool, `INSERT INTO batches (good_id, production_date) VALUES ($1::uuid,'2026-01-01') RETURNING id::text`, &fx.batch, fx.good)
	return fx
}

func mustScan(t *testing.T, pool *pgxpool.Pool, sql string, dst *string, args ...any) {
	t.Helper()
	if err := pool.QueryRow(context.Background(), sql, args...).Scan(dst); err != nil {
		t.Fatalf("seed %q: %v", sql, err)
	}
}

func (fx *stockFixture) keyA() model.StockKey {
	return model.StockKey{CellID: fx.cellA, GoodID: fx.good, BatchID: fx.batch}
}
func (fx *stockFixture) keyB() model.StockKey {
	return model.StockKey{CellID: fx.cellB, GoodID: fx.good, BatchID: fx.batch}
}

func TestStock_AddIncrements(t *testing.T) {
	fx := setupStock(t)
	repo := repository.NewStockRepository(fx.pool)
	ctx := context.Background()

	mustNoErr(t, repo.Add(ctx, fx.keyA(), decimal.NewFromInt(10)))
	assertQty(t, repo, fx.keyA(), "10")
	mustNoErr(t, repo.Add(ctx, fx.keyA(), decimal.RequireFromString("5.5"))) // дробное (кг)
	assertQty(t, repo, fx.keyA(), "15.5")
}

func TestStock_RemoveGuardsNegative(t *testing.T) {
	fx := setupStock(t)
	repo := repository.NewStockRepository(fx.pool)
	ctx := context.Background()

	mustNoErr(t, repo.Add(ctx, fx.keyA(), decimal.NewFromInt(10)))
	mustNoErr(t, repo.Remove(ctx, fx.keyA(), decimal.NewFromInt(4)))
	assertQty(t, repo, fx.keyA(), "6")

	// списать больше, чем есть → ErrInsufficientStock, остаток не меняется
	if err := repo.Remove(ctx, fx.keyA(), decimal.NewFromInt(10)); !errors.Is(err, repository.ErrInsufficientStock) {
		t.Fatalf("ожидалась ErrInsufficientStock, получено %v", err)
	}
	assertQty(t, repo, fx.keyA(), "6")
}

func TestStock_TransferAtomic(t *testing.T) {
	fx := setupStock(t)
	repo := repository.NewStockRepository(fx.pool)
	ctx := context.Background()

	mustNoErr(t, repo.Add(ctx, fx.keyA(), decimal.NewFromInt(10)))
	mustNoErr(t, repo.Transfer(ctx, fx.keyA(), fx.keyB(), decimal.NewFromInt(4)))
	assertQty(t, repo, fx.keyA(), "6")
	assertQty(t, repo, fx.keyB(), "4")

	// перенос больше, чем есть в источнике → откат: и источник, и приёмник без изменений
	if err := repo.Transfer(ctx, fx.keyA(), fx.keyB(), decimal.NewFromInt(100)); !errors.Is(err, repository.ErrInsufficientStock) {
		t.Fatalf("ожидалась ErrInsufficientStock, получено %v", err)
	}
	assertQty(t, repo, fx.keyA(), "6")
	assertQty(t, repo, fx.keyB(), "4") // приход НЕ применился (транзакция откатилась)
}

// TestStock_ConcurrentIssue — ⚠ ключевой тест: N параллельных списаний по 1 из остатка 100.
// Ровно 100 должны пройти, 100 — получить ErrInsufficientStock, итог = 0, минуса нет.
func TestStock_ConcurrentIssue(t *testing.T) {
	fx := setupStock(t)
	repo := repository.NewStockRepository(fx.pool)
	ctx := context.Background()

	const initial, workers = 100, 200
	mustNoErr(t, repo.Add(ctx, fx.keyA(), decimal.NewFromInt(initial)))

	var success, insufficient, other int64
	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			switch err := repo.Remove(ctx, fx.keyA(), decimal.NewFromInt(1)); {
			case err == nil:
				atomic.AddInt64(&success, 1)
			case errors.Is(err, repository.ErrInsufficientStock):
				atomic.AddInt64(&insufficient, 1)
			default:
				atomic.AddInt64(&other, 1)
			}
		}()
	}
	wg.Wait()

	if other != 0 {
		t.Fatalf("неожиданные ошибки в конкурентных списаниях: %d", other)
	}
	if success != initial {
		t.Fatalf("успешных списаний: ожидалось %d, получено %d", initial, success)
	}
	if insufficient != workers-initial {
		t.Fatalf("отказов: ожидалось %d, получено %d", workers-initial, insufficient)
	}
	assertQty(t, repo, fx.keyA(), "0") // остаток не ушёл в минус и не «потерялся»
}

func mustNoErr(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatalf("неожиданная ошибка: %v", err)
	}
}

func assertQty(t *testing.T, repo *repository.StockRepository, key model.StockKey, want string) {
	t.Helper()
	got, err := repo.GetQty(context.Background(), key)
	if err != nil {
		t.Fatalf("GetQty: %v", err)
	}
	if !got.Equal(decimal.RequireFromString(want)) {
		t.Fatalf("остаток: ожидалось %s, получено %s", want, got)
	}
}
