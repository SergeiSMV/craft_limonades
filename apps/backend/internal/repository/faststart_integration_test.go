package repository_test

import (
	"context"
	"testing"

	"github.com/shopspring/decimal"

	"craftwms/internal/repository"
)

// Тесты P-FS-02: GetOrCreate партии (без дублей) и SET остатка строки (перезапись, не приращение).
// Переиспользуют фикстуру setupStock (склад/ячейки/товар/партия) из stock_integration_test.go.

func TestBatch_GetOrCreate_idempotent(t *testing.T) {
	fx := setupStock(t) // сеет партию (good, 2026-01-01) как fx.batch
	repo := repository.NewBatchRepository(fx.pool)
	ctx := context.Background()

	// Существующая грань → та же партия, что засеяна (не создаём дубль).
	got, err := repo.GetOrCreate(ctx, fx.good, "2026-01-01")
	mustNoErr(t, err)
	if got != fx.batch {
		t.Fatalf("GetOrCreate существующей грани: ожидалась партия %s, получено %s", fx.batch, got)
	}
	// Повторный вызов той же грани → тот же id.
	again, err := repo.GetOrCreate(ctx, fx.good, "2026-01-01")
	mustNoErr(t, err)
	if again != got {
		t.Fatalf("повторный GetOrCreate: ожидался %s, получено %s", got, again)
	}
	// Другая дата того же товара → новая партия.
	other, err := repo.GetOrCreate(ctx, fx.good, "2026-05-05")
	mustNoErr(t, err)
	if other == got {
		t.Fatalf("другая дата выпуска должна дать новую партию, получен тот же id %s", other)
	}

	// Итог: у товара ровно 2 партии (2026-01-01 и 2026-05-05), дублей нет.
	var cnt int
	if err := fx.pool.QueryRow(ctx, `SELECT count(*) FROM batches WHERE good_id = $1::uuid`, fx.good).Scan(&cnt); err != nil {
		t.Fatalf("count batches: %v", err)
	}
	if cnt != 2 {
		t.Fatalf("ожидалось 2 партии товара, получено %d", cnt)
	}
}

func TestStock_Set_overwrites(t *testing.T) {
	fx := setupStock(t)
	repo := repository.NewStockRepository(fx.pool)
	ctx := context.Background()

	// Нет строки → создаётся с точным значением.
	mustNoErr(t, repo.Set(ctx, fx.keyA(), decimal.RequireFromString("10.5")))
	assertQty(t, repo, fx.keyA(), "10.5")

	// SET перезаписывает (не прибавляет): 3, а не 13.5.
	mustNoErr(t, repo.Set(ctx, fx.keyA(), decimal.NewFromInt(3)))
	assertQty(t, repo, fx.keyA(), "3")

	// SET в ноль допустим — строка остаётся с qty=0.
	mustNoErr(t, repo.Set(ctx, fx.keyA(), decimal.Zero))
	assertQty(t, repo, fx.keyA(), "0")
}

func TestStock_Set_negativeRejectedByCheck(t *testing.T) {
	fx := setupStock(t)
	repo := repository.NewStockRepository(fx.pool)
	ctx := context.Background()

	// Отрицательное значение отсекает CHECK(qty>=0) в БД (страховка к валидации сервиса).
	if err := repo.Set(ctx, fx.keyA(), decimal.NewFromInt(-1)); err == nil {
		t.Fatalf("ожидалась ошибка БД на отрицательный остаток, получено nil")
	}
}
