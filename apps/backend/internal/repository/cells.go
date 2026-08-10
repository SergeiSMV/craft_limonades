package repository

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/model"
)

// CellRepository — доступ к таблице cells (физические ячейки хранения). Пока — апсерт под импорт;
// чтение/поиск добавятся в P1-06.
type CellRepository struct {
	pool *pgxpool.Pool
}

// NewCellRepository создаёт репозиторий ячеек.
func NewCellRepository(pool *pgxpool.Pool) *CellRepository {
	return &CellRepository{pool: pool}
}

// LabelsByWarehouse возвращает все активные ячейки склада (адрес + признак напольной) для печати
// этикеток (P-FS-05). Без пагинации — этикетки печатаются на весь склад; порядок (натуральная
// сортировка по адресу) делается на уровне сервиса.
func (r *CellRepository) LabelsByWarehouse(ctx context.Context, warehouseID string) ([]model.CellLabel, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT address, is_floor FROM cells
		WHERE warehouse_id = $1::uuid AND is_active = true`, warehouseID)
	if err != nil {
		return nil, fmt.Errorf("cells for labels: %w", err)
	}
	defer rows.Close()

	out := make([]model.CellLabel, 0)
	for rows.Next() {
		var c model.CellLabel
		if err := rows.Scan(&c.Address, &c.IsFloor); err != nil {
			return nil, fmt.Errorf("scan cell label: %w", err)
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// Upsert заводит/обновляет ячейку по (warehouse_id, address) — ключ уникальности из P1-01.
// Возвращает created=true, если строка вставлена (новая ячейка), false — если обновлена (повторный импорт).
// Идемпотентно: повторный импорт того же файла не двоит ячейки, при повторе обновляет is_floor.
func (r *CellRepository) Upsert(ctx context.Context, q Querier, warehouseID, address string, isFloor bool) (bool, error) {
	var inserted bool
	// (xmax = 0) — идиома Postgres: у только что вставленной строки xmax=0 → created=true;
	// у обновлённой по ON CONFLICT xmax≠0 → created=false.
	err := q.QueryRow(ctx, `
		INSERT INTO cells (warehouse_id, address, is_floor)
		VALUES ($1::uuid, $2, $3)
		ON CONFLICT (warehouse_id, address) DO UPDATE SET is_floor = EXCLUDED.is_floor
		RETURNING (xmax = 0) AS inserted`,
		warehouseID, address, isFloor).Scan(&inserted)
	if err != nil {
		return false, fmt.Errorf("upsert cell %q: %w", address, err)
	}
	return inserted, nil
}
