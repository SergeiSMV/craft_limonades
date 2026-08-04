package repository

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"
)

// WarehouseRepository — доступ к таблице warehouses (физические/внешние склады, напр. «Шабулина»).
// Ячейки принадлежат физическому складу; «внутренний склад» (основной/брак) — измерение остатка, не склада.
type WarehouseRepository struct {
	pool *pgxpool.Pool
}

// NewWarehouseRepository создаёт репозиторий складов.
func NewWarehouseRepository(pool *pgxpool.Pool) *WarehouseRepository {
	return &WarehouseRepository{pool: pool}
}

// Upsert заводит/обновляет физический склад по code (ключ дедупа) и возвращает его id.
// Идемпотентно: повторный импорт с тем же code не двоит склад, обновляет только name.
func (r *WarehouseRepository) Upsert(ctx context.Context, q Querier, code, name string) (string, error) {
	var id string
	err := q.QueryRow(ctx, `
		INSERT INTO warehouses (code, name) VALUES ($1, $2)
		ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name
		RETURNING id::text`, code, name).Scan(&id)
	if err != nil {
		return "", fmt.Errorf("upsert warehouse %q: %w", code, err)
	}
	return id, nil
}
