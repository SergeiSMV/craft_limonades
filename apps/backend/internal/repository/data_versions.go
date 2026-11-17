package repository

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"
)

// DataVersionRepository читает версии данных по областям (ADHOC-60, миграция 43).
//
// Версии повышают триггеры в транзакциях правок; здесь только чтение - его делает middleware
// на каждый ответ API, поэтому запрос один и по крошечной таблице.
type DataVersionRepository struct {
	pool *pgxpool.Pool
}

// NewDataVersionRepository - репозиторий версий данных.
func NewDataVersionRepository(pool *pgxpool.Pool) *DataVersionRepository {
	return &DataVersionRepository{pool: pool}
}

// DataVersions - версии всех областей: область → счётчик.
func (r *DataVersionRepository) DataVersions(ctx context.Context) (map[string]int64, error) {
	rows, err := r.pool.Query(ctx, `SELECT domain, version FROM data_versions`)
	if err != nil {
		return nil, fmt.Errorf("версии данных: %w", err)
	}
	defer rows.Close()
	out := map[string]int64{}
	for rows.Next() {
		var domain string
		var version int64
		if err := rows.Scan(&domain, &version); err != nil {
			return nil, fmt.Errorf("разобрать версию данных: %w", err)
		}
		out[domain] = version
	}
	return out, rows.Err()
}
