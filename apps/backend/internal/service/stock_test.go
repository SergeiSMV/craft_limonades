package service

import (
	"context"
	"errors"
	"testing"

	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// fakeStockRepo - in-memory реализация stockRepo для юнит-тестов сервиса (без БД).
// Проверяем ЛОГИКУ сервиса (валидация, маппинг ошибок), а не атомарность SQL -
// её проверяет интеграционный тест репозитория (stock_integration_test.go).
type fakeStockRepo struct {
	qty          map[model.StockKey]decimal.Decimal
	insufficient bool // при true Remove/Transfer возвращают repository.ErrInsufficientStock
	addCalls     int
	setCalls     int
	removeCalls  int
	transferred  bool
	lastFrom     model.StockKey
	lastTo       model.StockKey
}

func newFakeStockRepo() *fakeStockRepo {
	return &fakeStockRepo{qty: map[model.StockKey]decimal.Decimal{}}
}

func (f *fakeStockRepo) Add(_ context.Context, key model.StockKey, qty decimal.Decimal) error {
	f.addCalls++
	f.qty[key] = f.qty[key].Add(qty)
	return nil
}

func (f *fakeStockRepo) Set(_ context.Context, key model.StockKey, qty decimal.Decimal) error {
	f.setCalls++
	f.qty[key] = qty // SET: перезапись, не приращение
	return nil
}

func (f *fakeStockRepo) Remove(_ context.Context, key model.StockKey, qty decimal.Decimal) error {
	f.removeCalls++
	if f.insufficient {
		return repository.ErrInsufficientStock
	}
	f.qty[key] = f.qty[key].Sub(qty)
	return nil
}

func (f *fakeStockRepo) Transfer(_ context.Context, from, to model.StockKey, _ decimal.Decimal) error {
	if f.insufficient {
		return repository.ErrInsufficientStock
	}
	f.transferred = true
	f.lastFrom, f.lastTo = from, to
	return nil
}

func (f *fakeStockRepo) GetQty(_ context.Context, key model.StockKey) (decimal.Decimal, error) {
	return f.qty[key], nil
}

var testKey = model.StockKey{CellID: "cell-1", GoodID: "good-1", BatchID: "batch-1"}

func TestReceive_positive_callsAdd(t *testing.T) {
	repo := newFakeStockRepo()
	svc := NewStockService(repo)

	if err := svc.Receive(context.Background(), testKey, decimal.NewFromInt(10)); err != nil {
		t.Fatalf("Receive: неожиданная ошибка: %v", err)
	}
	if repo.addCalls != 1 {
		t.Fatalf("ожидался 1 вызов Add, получено %d", repo.addCalls)
	}
	if got := repo.qty[testKey]; !got.Equal(decimal.NewFromInt(10)) {
		t.Fatalf("остаток: ожидалось 10, получено %s", got)
	}
}

func TestReceive_nonPositive_rejected(t *testing.T) {
	for _, qty := range []decimal.Decimal{decimal.Zero, decimal.NewFromInt(-5)} {
		repo := newFakeStockRepo()
		svc := NewStockService(repo)
		err := svc.Receive(context.Background(), testKey, qty)
		if !errors.Is(err, ErrInvalidQuantity) {
			t.Fatalf("qty=%s: ожидалась ErrInvalidQuantity, получено %v", qty, err)
		}
		if repo.addCalls != 0 {
			t.Fatalf("qty=%s: Add не должен вызываться при невалидном количестве", qty)
		}
	}
}

func TestSetLine_setsExact_overwrites(t *testing.T) {
	repo := newFakeStockRepo()
	svc := NewStockService(repo)
	ctx := context.Background()

	if err := svc.SetLine(ctx, testKey, decimal.NewFromInt(10)); err != nil {
		t.Fatalf("SetLine(10): неожиданная ошибка: %v", err)
	}
	if got := repo.qty[testKey]; !got.Equal(decimal.NewFromInt(10)) {
		t.Fatalf("после SetLine(10): ожидалось 10, получено %s", got)
	}
	// SET перезаписывает, а не прибавляет: 3, а не 13.
	if err := svc.SetLine(ctx, testKey, decimal.NewFromInt(3)); err != nil {
		t.Fatalf("SetLine(3): неожиданная ошибка: %v", err)
	}
	if got := repo.qty[testKey]; !got.Equal(decimal.NewFromInt(3)) {
		t.Fatalf("после SetLine(3): ожидалось 3 (перезапись), получено %s", got)
	}
	if repo.setCalls != 2 {
		t.Fatalf("ожидалось 2 вызова Set, получено %d", repo.setCalls)
	}
}

func TestSetLine_zeroAllowed(t *testing.T) {
	repo := newFakeStockRepo()
	svc := NewStockService(repo)
	if err := svc.SetLine(context.Background(), testKey, decimal.Zero); err != nil {
		t.Fatalf("SetLine(0) должен быть допустим (напр. после Undo), получено %v", err)
	}
	if repo.setCalls != 1 {
		t.Fatalf("ожидался 1 вызов Set при qty=0, получено %d", repo.setCalls)
	}
}

func TestSetLine_negativeRejected(t *testing.T) {
	repo := newFakeStockRepo()
	svc := NewStockService(repo)
	err := svc.SetLine(context.Background(), testKey, decimal.NewFromInt(-1))
	if !errors.Is(err, ErrInvalidQuantity) {
		t.Fatalf("ожидалась ErrInvalidQuantity, получено %v", err)
	}
	if repo.setCalls != 0 {
		t.Fatalf("Set не должен вызываться при отрицательном qty")
	}
}

func TestIssue_insufficient_mappedToServiceError(t *testing.T) {
	repo := newFakeStockRepo()
	repo.insufficient = true
	svc := NewStockService(repo)

	err := svc.Issue(context.Background(), testKey, decimal.NewFromInt(1))
	if !errors.Is(err, ErrInsufficientStock) {
		t.Fatalf("ожидалась service.ErrInsufficientStock, получено %v", err)
	}
}

func TestIssue_nonPositive_rejected(t *testing.T) {
	repo := newFakeStockRepo()
	svc := NewStockService(repo)
	err := svc.Issue(context.Background(), testKey, decimal.Zero)
	if !errors.Is(err, ErrInvalidQuantity) {
		t.Fatalf("ожидалась ErrInvalidQuantity, получено %v", err)
	}
	if repo.removeCalls != 0 {
		t.Fatalf("Remove не должен вызываться при невалидном количестве")
	}
}

func TestTransfer_buildsKeysAndValidates(t *testing.T) {
	repo := newFakeStockRepo()
	svc := NewStockService(repo)

	// невалидное количество - отказ до репозитория
	if err := svc.Transfer(context.Background(), "c1", "c2", "g", "b", "iwh", decimal.Zero); !errors.Is(err, ErrInvalidQuantity) {
		t.Fatalf("ожидалась ErrInvalidQuantity, получено %v", err)
	}
	// валидное - перенос выполнен
	if err := svc.Transfer(context.Background(), "c1", "c2", "g", "b", "iwh", decimal.NewFromInt(3)); err != nil {
		t.Fatalf("Transfer: неожиданная ошибка: %v", err)
	}
	if !repo.transferred {
		t.Fatalf("ожидался вызов Transfer в репозитории")
	}
	// Учётная принадлежность не меняется при переносе: она одна и та же с обеих сторон.
	if repo.lastFrom.InternalWarehouseID != "iwh" || repo.lastTo.InternalWarehouseID != "iwh" {
		t.Errorf("внутренний склад потерян при переносе: from=%q to=%q",
			repo.lastFrom.InternalWarehouseID, repo.lastTo.InternalWarehouseID)
	}
}

func TestTransfer_insufficient_mapped(t *testing.T) {
	repo := newFakeStockRepo()
	repo.insufficient = true
	svc := NewStockService(repo)
	err := svc.Transfer(context.Background(), "c1", "c2", "g", "b", "iwh", decimal.NewFromInt(3))
	if !errors.Is(err, ErrInsufficientStock) {
		t.Fatalf("ожидалась ErrInsufficientStock, получено %v", err)
	}
}
