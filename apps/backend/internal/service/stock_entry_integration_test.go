package service_test

import (
	"context"
	"errors"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/internal/service"
	"craftwms/internal/testutil"
)

// seEnv — окружение теста сессии ввода: сервис + справочники (склад, ячейки, товары, пользователь).
type seEnv struct {
	svc          *service.StockEntryService
	stockRepo    *repository.StockRepository
	barcodeRepo  *repository.BarcodeRepository
	warehouse    string
	cell1, cell2 string
	good1, good2 string
	user         string
}

func setupStockEntry(t *testing.T) (*pgxpool.Pool, *seEnv) {
	t.Helper()
	pool := testutil.StartPostgres(t)
	ctx := context.Background()

	env := &seEnv{
		svc:         service.NewStockEntryService(repository.NewStockEntryRepository(pool)),
		stockRepo:   repository.NewStockRepository(pool),
		barcodeRepo: repository.NewBarcodeRepository(pool),
		good1:       seedGood(t, pool, "Товар 1"),
		good2:       seedGood(t, pool, "Товар 2"),
	}
	must := func(sql string, dst *string, args ...any) {
		if err := pool.QueryRow(ctx, sql, args...).Scan(dst); err != nil {
			t.Fatalf("seed %q: %v", sql, err)
		}
	}
	must(`INSERT INTO warehouses (code,name) VALUES ('SHB','Шабулина') RETURNING id::text`, &env.warehouse)
	must(`INSERT INTO cells (warehouse_id,address) VALUES ($1::uuid,'M1-1-1-1') RETURNING id::text`, &env.cell1, env.warehouse)
	must(`INSERT INTO cells (warehouse_id,address) VALUES ($1::uuid,'M1-1-1-2') RETURNING id::text`, &env.cell2, env.warehouse)
	must(`INSERT INTO users (login,password_hash,full_name) VALUES ('90000009','x','Кладовщик') RETURNING id::text`, &env.user)
	return pool, env
}

func (e *seEnv) qty(t *testing.T, cell, good, batch string) decimal.Decimal {
	t.Helper()
	q, err := e.stockRepo.GetQty(context.Background(), model.StockKey{CellID: cell, GoodID: good, BatchID: batch})
	if err != nil {
		t.Fatalf("GetQty: %v", err)
	}
	return q
}

// batchOf находит id партии по (товар, дата ISO) — для сверки записанного остатка.
func batchOf(t *testing.T, pool *pgxpool.Pool, good, dateISO string) string {
	t.Helper()
	var id string
	if err := pool.QueryRow(context.Background(),
		`SELECT id::text FROM batches WHERE good_id=$1::uuid AND production_date=$2::date`, good, dateISO).Scan(&id); err != nil {
		t.Fatalf("batchOf(%s,%s): %v", good, dateISO, err)
	}
	return id
}

// TestStockEntry_fullCycle — старт → checkpoint(ы) → финал → остаток в stock; SET-перезапись грани.
func TestStockEntry_fullCycle(t *testing.T) {
	pool, env := setupStockEntry(t)
	ctx := context.Background()

	sess, err := env.svc.Start(ctx, "", env.warehouse, env.user)
	if err != nil {
		t.Fatalf("Start: %v", err)
	}

	// Checkpoint ячейки 1: строка good1@15-01-2026 = 10 + попутная привязка ШК к good2.
	err = env.svc.Checkpoint(ctx, sess, env.cell1,
		[]service.EntryLine{{GoodID: env.good1, ProductionDate: "15-01-2026", Qty: decimal.NewFromInt(10)}},
		[]service.EntryBarcode{{GoodID: env.good2, Barcode: "4600000000017", Symbology: "ean13"}})
	if err != nil {
		t.Fatalf("Checkpoint cell1: %v", err)
	}

	// Повторный checkpoint той же грани в ячейке 1 → SET перезаписывает (было 10, стало 7).
	err = env.svc.Checkpoint(ctx, sess, env.cell1,
		[]service.EntryLine{{GoodID: env.good1, ProductionDate: "15-01-2026", Qty: decimal.NewFromInt(7)}}, nil)
	if err != nil {
		t.Fatalf("Checkpoint cell1 повтор: %v", err)
	}

	// Ячейка 2: good1 другой партии (20-02-2026) = 5.
	err = env.svc.Checkpoint(ctx, sess, env.cell2,
		[]service.EntryLine{{GoodID: env.good1, ProductionDate: "20-02-2026", Qty: decimal.RequireFromString("5.5")}}, nil)
	if err != nil {
		t.Fatalf("Checkpoint cell2: %v", err)
	}

	// Финал: строки сессии переносятся в stock (SET) одной транзакцией, сессия закрывается.
	written, err := env.svc.Finalize(ctx, sess)
	if err != nil {
		t.Fatalf("Finalize: %v", err)
	}
	if written != 2 {
		t.Fatalf("ожидалось 2 записанных строки (2 грани), получено %d", written)
	}

	// Остатки в stock соответствуют последнему SET по каждой грани.
	batch1 := batchOf(t, pool, env.good1, "2026-01-15")
	batch2 := batchOf(t, pool, env.good1, "2026-02-20")
	if got := env.qty(t, env.cell1, env.good1, batch1); !got.Equal(decimal.NewFromInt(7)) {
		t.Fatalf("остаток cell1/good1/batch1: ожидалось 7 (перезапись), получено %s", got)
	}
	if got := env.qty(t, env.cell2, env.good1, batch2); !got.Equal(decimal.RequireFromString("5.5")) {
		t.Fatalf("остаток cell2/good1/batch2: ожидалось 5.5, получено %s", got)
	}

	// Попутная привязка ШК доехала (good2).
	g, err := env.barcodeRepo.GetGoodByBarcode(ctx, "4600000000017")
	if err != nil || g.ID != env.good2 {
		t.Fatalf("привязка ШК: ожидался good2=%s, получено id=%s err=%v", env.good2, g.ID, err)
	}

	// Повторный финал закрытой сессии → ErrSessionClosed.
	if _, err := env.svc.Finalize(ctx, sess); !errors.Is(err, repository.ErrSessionClosed) {
		t.Fatalf("повторный Finalize: ожидалась ErrSessionClosed, получено %v", err)
	}
	// Checkpoint по закрытой сессии → ErrSessionClosed.
	err = env.svc.Checkpoint(ctx, sess, env.cell1,
		[]service.EntryLine{{GoodID: env.good1, ProductionDate: "15-01-2026", Qty: decimal.NewFromInt(1)}}, nil)
	if !errors.Is(err, repository.ErrSessionClosed) {
		t.Fatalf("Checkpoint закрытой: ожидалась ErrSessionClosed, получено %v", err)
	}
}

// TestStockEntry_validation — негативы валидации/несуществующей сессии.
func TestStockEntry_validation(t *testing.T) {
	_, env := setupStockEntry(t)
	ctx := context.Background()

	if _, err := env.svc.Start(ctx, "", "   ", env.user); !errors.Is(err, service.ErrEmptyWarehouse) {
		t.Fatalf("пустой склад: ожидалась ErrEmptyWarehouse, получено %v", err)
	}

	sess, err := env.svc.Start(ctx, "", env.warehouse, env.user)
	if err != nil {
		t.Fatalf("Start: %v", err)
	}

	// Неверный формат даты → ErrInvalidDate.
	err = env.svc.Checkpoint(ctx, sess, env.cell1,
		[]service.EntryLine{{GoodID: env.good1, ProductionDate: "2026-01-15", Qty: decimal.NewFromInt(1)}}, nil)
	if !errors.Is(err, service.ErrInvalidDate) {
		t.Fatalf("дата ISO вместо DD-MM-YYYY: ожидалась ErrInvalidDate, получено %v", err)
	}
	// Отрицательное количество → ErrInvalidQuantity.
	err = env.svc.Checkpoint(ctx, sess, env.cell1,
		[]service.EntryLine{{GoodID: env.good1, ProductionDate: "15-01-2026", Qty: decimal.NewFromInt(-1)}}, nil)
	if !errors.Is(err, service.ErrInvalidQuantity) {
		t.Fatalf("отрицательное qty: ожидалась ErrInvalidQuantity, получено %v", err)
	}
	// Пустая ячейка → ErrEmptyCell.
	if err := env.svc.Checkpoint(ctx, sess, "  ", nil, nil); !errors.Is(err, service.ErrEmptyCell) {
		t.Fatalf("пустая ячейка: ожидалась ErrEmptyCell, получено %v", err)
	}

	// Несуществующая сессия → ErrSessionNotFound.
	missing := "00000000-0000-0000-0000-0000000000ff"
	if _, err := env.svc.Finalize(ctx, missing); !errors.Is(err, repository.ErrSessionNotFound) {
		t.Fatalf("финал несуществующей: ожидалась ErrSessionNotFound, получено %v", err)
	}
}
