package service

import (
	"context"

	"github.com/shopspring/decimal"

	"craftwms/internal/model"
)

// stockRepo - то, что StockService нужно от хранилища (зависимость от интерфейса).
type stockRepo interface {
	Add(ctx context.Context, key model.StockKey, qty decimal.Decimal) error
	Set(ctx context.Context, key model.StockKey, qty decimal.Decimal) error
	Remove(ctx context.Context, key model.StockKey, qty decimal.Decimal) error
	Transfer(ctx context.Context, from, to model.StockKey, qty decimal.Decimal) error
	GetQty(ctx context.Context, key model.StockKey) (decimal.Decimal, error)
}

// StockService - доменные операции над остатком: приход, расход, перенос между ячейками.
// Атомарность обеспечивает репозиторий (одиночные upsert/guarded-update и транзакция в Transfer);
// сервис отвечает за валидацию; ошибки-сигналы общие с репозиторием и лежат в model.
type StockService struct {
	stock stockRepo
}

// NewStockService собирает сервис из репозитория остатков.
func NewStockService(stock stockRepo) *StockService {
	return &StockService{stock: stock}
}

// Receive - приход: положить qty товара (партии) в ячейку.
func (s *StockService) Receive(ctx context.Context, key model.StockKey, qty decimal.Decimal) error {
	if !qty.IsPositive() {
		return model.ErrInvalidQuantity
	}
	return s.stock.Add(ctx, key, qty)
}

// SetLine - установить остаток грани (ячейка×товар×партия) в ТОЧНОЕ значение qty (SET, ввод
// остатков P-FastStart): «в ячейке ровно столько». В отличие от Receive/Issue направление не
// задаётся - это перезапись. Отрицательное отклоняем; ноль допустим (напр. после Undo строки).
func (s *StockService) SetLine(ctx context.Context, key model.StockKey, qty decimal.Decimal) error {
	if qty.IsNegative() {
		return model.ErrInvalidQuantity
	}
	return s.stock.Set(ctx, key, qty)
}

// Issue - расход: снять qty товара (партии) из ячейки. Не хватило → ErrInsufficientStock.
func (s *StockService) Issue(ctx context.Context, key model.StockKey, qty decimal.Decimal) error {
	if !qty.IsPositive() {
		return model.ErrInvalidQuantity
	}
	return s.stock.Remove(ctx, key, qty)
}

// Transfer - перенести qty товара (партии) из ячейки fromCell в toCell (атомарно).
//
// Учётная принадлежность (внутренний склад) при переносе НЕ меняется: перемещение отвечает
// на вопрос «где лежит», а не «чей это остаток». Перевод между внутренними складами -
// отдельная операция, потому что это учётное решение человека, а не следствие переноса коробки.
func (s *StockService) Transfer(ctx context.Context, fromCell, toCell, goodID, batchID, internalWarehouseID string, qty decimal.Decimal) error {
	if !qty.IsPositive() {
		return model.ErrInvalidQuantity
	}
	from := model.StockKey{CellID: fromCell, GoodID: goodID, BatchID: batchID, InternalWarehouseID: internalWarehouseID}
	to := model.StockKey{CellID: toCell, GoodID: goodID, BatchID: batchID, InternalWarehouseID: internalWarehouseID}
	return s.stock.Transfer(ctx, from, to, qty)
}
