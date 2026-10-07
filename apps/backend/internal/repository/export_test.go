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
