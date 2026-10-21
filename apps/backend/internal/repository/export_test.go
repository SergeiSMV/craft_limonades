package repository

import (
	"context"

	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/model"
)

// PlaceLoadUnitForTest открывает тестам пакета repository_test общую функцию размещения ГЕ.
// Своей публичной операции у размещения до P5-02 нет, а инвариант журнала проверять надо сейчас.
func PlaceLoadUnitForTest(ctx context.Context, pool *pgxpool.Pool, in model.PlaceLoadUnitInput) error {
	return WithinTx(ctx, pool, func(q Querier) error { return placeLoadUnit(ctx, q, in) })
}

// MovementSubmitForTest открывает тестам проведение документа движения (P6-02). Публичная
// операция очереди появится в P6-03 вместе с веткой товара.
func MovementSubmitForTest(ctx context.Context, pool *pgxpool.Pool, in MovementSubmitInput) (int, error) {
	var n int
	err := WithinTx(ctx, pool, func(q Querier) error {
		var err error
		n, err = movementSubmit(ctx, q, in)
		return err
	})
	return n, err
}

// ProblemSubmitForTest открывает тестам фиксацию проблемы склада (P6-07-1) в своей транзакции.
func ProblemSubmitForTest(ctx context.Context, pool *pgxpool.Pool, in ProblemSubmitInput) error {
	return WithinTx(ctx, pool, func(q Querier) error { return problemSubmit(ctx, q, in) })
}
