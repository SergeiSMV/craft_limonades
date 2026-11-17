package repository_test

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// Тесты P4-01-1 (ADR-0016): внутренний склад - измерение остатка.
// Переиспользуют фикстуру setupStock, которая теперь отдаёт и склады: fx.iwh («основной»
// по умолчанию) и fx.iwhDefect («брак»).

// Главный критерий задачи: одна физическая ячейка одновременно держит остаток «основного»
// и «брака», и операции их не смешивают.
func TestInternalWarehouse_oneCellHoldsBothStocks(t *testing.T) {
	fx := setupStock(t)
	ctx := context.Background()
	repo := repository.NewStockRepository(fx.pool)

	main := model.StockKey{CellID: fx.cellA, GoodID: fx.good, BatchID: fx.batch, InternalWarehouseID: fx.iwh}
	defect := model.StockKey{CellID: fx.cellA, GoodID: fx.good, BatchID: fx.batch, InternalWarehouseID: fx.iwhDefect}

	if err := repo.Add(ctx, main, decimal.NewFromInt(10)); err != nil {
		t.Fatalf("приход на основной: %v", err)
	}
	if err := repo.Add(ctx, defect, decimal.NewFromInt(3)); err != nil {
		t.Fatalf("приход на брак: %v", err)
	}

	// Две отдельные строки, а не одна затёртая: до расширения грани второй приход переписал бы первый.
	gotMain, err := repo.GetQty(ctx, main)
	if err != nil {
		t.Fatalf("остаток основного: %v", err)
	}
	gotDefect, err := repo.GetQty(ctx, defect)
	if err != nil {
		t.Fatalf("остаток брака: %v", err)
	}
	if !gotMain.Equal(decimal.NewFromInt(10)) || !gotDefect.Equal(decimal.NewFromInt(3)) {
		t.Fatalf("остатки смешались: основной=%s брак=%s, ожидались 10 и 3", gotMain, gotDefect)
	}

	// Расход с брака не трогает основной - операции адресуются по полной грани.
	if err := repo.Remove(ctx, defect, decimal.NewFromInt(3)); err != nil {
		t.Fatalf("расход с брака: %v", err)
	}
	gotMain, _ = repo.GetQty(ctx, main)
	if !gotMain.Equal(decimal.NewFromInt(10)) {
		t.Errorf("расход с брака задел основной: %s", gotMain)
	}

	// Итог по физической ячейке - сумма по внутренним складам: именно его должен видеть
	// кладовщик, чтобы понимать фактическое количество на складе.
	var total string
	if err := fx.pool.QueryRow(ctx,
		`SELECT sum(qty)::text FROM stock WHERE cell_id = $1::uuid AND good_id = $2::uuid`,
		fx.cellA, fx.good).Scan(&total); err != nil {
		t.Fatalf("итог по ячейке: %v", err)
	}
	if !strings.HasPrefix(total, "10") {
		t.Errorf("итог по ячейке: %q, ожидался 10", total)
	}
}

// Ключ без учётной принадлежности не должен доходить до БД: поле добавилось к StockKey позже,
// и литерал структуры без него компилируется молча. Внятная ошибка вместо «invalid uuid»
// экономит разбор в P4-03/P5/P6, где ключ будут собирать заново.
func TestInternalWarehouse_incompleteKeyRejected(t *testing.T) {
	fx := setupStock(t)
	ctx := context.Background()
	repo := repository.NewStockRepository(fx.pool)
	key := model.StockKey{CellID: fx.cellA, GoodID: fx.good, BatchID: fx.batch} // без склада

	if err := repo.Add(ctx, key, decimal.NewFromInt(1)); !errors.Is(err, repository.ErrEmptyInternalWarehouse) {
		t.Errorf("Add: ожидалась ErrEmptyInternalWarehouse, получено %v", err)
	}
	if err := repo.Set(ctx, key, decimal.NewFromInt(1)); !errors.Is(err, repository.ErrEmptyInternalWarehouse) {
		t.Errorf("Set: ожидалась ErrEmptyInternalWarehouse, получено %v", err)
	}
	if err := repo.Remove(ctx, key, decimal.NewFromInt(1)); !errors.Is(err, repository.ErrEmptyInternalWarehouse) {
		t.Errorf("Remove: ожидалась ErrEmptyInternalWarehouse, получено %v", err)
	}
	if _, err := repo.GetQty(ctx, key); !errors.Is(err, repository.ErrEmptyInternalWarehouse) {
		t.Errorf("GetQty: ожидалась ErrEmptyInternalWarehouse, получено %v", err)
	}
}

// Справочник пополняемый: новый склад заводится вставкой и сразу годится как измерение остатка.
// Склад по умолчанию при этом ровно один - за этим следит частичный уникальный индекс.
func TestInternalWarehouse_directoryIsExtendable(t *testing.T) {
	fx := setupStock(t)
	ctx := context.Background()

	var custom string
	mustScan(t, fx.pool, `
		INSERT INTO internal_warehouses (code, name) VALUES ('QUARANTINE','Карантин')
		RETURNING id::text`, &custom)

	repo := repository.NewStockRepository(fx.pool)
	key := model.StockKey{CellID: fx.cellB, GoodID: fx.good, BatchID: fx.batch, InternalWarehouseID: custom}
	if err := repo.Add(ctx, key, decimal.NewFromInt(4)); err != nil {
		t.Fatalf("остаток на новом складе: %v", err)
	}
	got, _ := repo.GetQty(ctx, key)
	if !got.Equal(decimal.NewFromInt(4)) {
		t.Errorf("остаток на новом складе: %s, ожидался 4", got)
	}

	// Второй склад по умолчанию завести нельзя - иначе «куда приходовать» стало бы неоднозначным.
	if _, err := fx.pool.Exec(ctx,
		`UPDATE internal_warehouses SET is_default = true WHERE code = 'DEFECT'`); err == nil {
		t.Error("удалось завести второй склад по умолчанию")
	}
}
