package repository

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"
)

// BatchRepository — доступ к таблице batches (партия = товар + дата выпуска).
type BatchRepository struct {
	pool *pgxpool.Pool
}

// NewBatchRepository создаёт репозиторий партий.
func NewBatchRepository(pool *pgxpool.Pool) *BatchRepository {
	return &BatchRepository{pool: pool}
}

// GetOrCreate возвращает id партии для грани (good_id, production_date), создавая её при
// отсутствии. Идемпотентно: повторный вызов той же грани отдаёт ту же партию без дубля
// (гарантирует UNIQUE(good_id, production_date)). productionDate — строка 'YYYY-MM-DD'.
// Нужен вводу остатков (P-FastStart): партия определяется датой выпуска на проходе.
func (r *BatchRepository) GetOrCreate(ctx context.Context, goodID, productionDate string) (string, error) {
	return getOrCreateBatch(ctx, r.pool, goodID, productionDate)
}

// getOrCreateBatch — низкоуровневая версия на Querier (пул или tx), чтобы финал сессии (P-FS-04)
// мог резолвить партии внутри транзакции.
//
// Как: CTE — сначала пытаемся вставить (ON CONFLICT DO NOTHING, чтобы НЕ трогать updated_at
// существующей партии на «get»), затем UNION ALL с выборкой уже существующей; LIMIT 1 берёт
// вставленную строку, если она была, иначе найденную. Дату передаём строкой и приводим $2::date.
func getOrCreateBatch(ctx context.Context, q Querier, goodID, productionDate string) (string, error) {
	var id string
	err := q.QueryRow(ctx, `
		WITH ins AS (
			INSERT INTO batches (good_id, production_date)
			VALUES ($1, $2::date)
			ON CONFLICT (good_id, production_date) DO NOTHING
			RETURNING id
		)
		SELECT id::text FROM ins
		UNION ALL
		SELECT id::text FROM batches WHERE good_id = $1 AND production_date = $2::date
		LIMIT 1`,
		goodID, productionDate,
	).Scan(&id)
	if err != nil {
		return "", fmt.Errorf("get-or-create batch: %w", err)
	}
	return id, nil
}
