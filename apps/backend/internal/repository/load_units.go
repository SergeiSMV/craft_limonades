package repository

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/model"
)

// ErrLoadUnitNotFound — нет грузовой единицы с таким идентификатором.
//
// Отдельная ошибка, а не нарушение внешнего ключа из строки приёмки: кладовщик сканировал ярлык
// короба, которого система не знает, и это разбирается человеком, а не показывается как сбой БД.
var ErrLoadUnitNotFound = errors.New("load unit not found")

// LoadUnitRepository — грузовая единица: заведение короба и его чтение (P4-01, P4-03).
type LoadUnitRepository struct {
	pool *pgxpool.Pool
}

// NewLoadUnitRepository создаёт репозиторий грузовых единиц.
func NewLoadUnitRepository(pool *pgxpool.Pool) *LoadUnitRepository {
	return &LoadUnitRepository{pool: pool}
}

// Create заводит ГЕ с идентификатором, выданным устройством, идемпотентно.
//
// Зачем id с устройства: короб получает QR-ярлык в момент сборки, в том числе без сети (P4-04),
// и серверный идентификатор взять неоткуда — напечатанный ярлык уже уехал на коробе.
// Повтор с тем же id ничего не меняет: очередь устройства повторяет операцию до подтверждения,
// и второй короб на том же ярлыке означал бы две ГЕ на одну наклейку.
func (r *LoadUnitRepository) Create(ctx context.Context, id, kind string) error {
	_, err := r.pool.Exec(ctx, `
		INSERT INTO load_units (id, kind) VALUES ($1::uuid, $2)
		ON CONFLICT (id) DO NOTHING`, id, kind)
	if err != nil {
		return fmt.Errorf("создать ГЕ: %w", err)
	}
	return nil
}

// ByID возвращает шапку ГЕ или ErrLoadUnitNotFound.
func (r *LoadUnitRepository) ByID(ctx context.Context, id string) (model.LoadUnit, error) {
	var lu model.LoadUnit
	err := r.pool.QueryRow(ctx, `
		SELECT id::text, kind, parent_id::text, cell_id::text, status, created_at
		FROM load_units WHERE id = $1::uuid`, id).
		Scan(&lu.ID, &lu.Kind, &lu.ParentID, &lu.CellID, &lu.Status, &lu.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return model.LoadUnit{}, ErrLoadUnitNotFound
	}
	if err != nil {
		return model.LoadUnit{}, fmt.Errorf("прочитать ГЕ: %w", err)
	}
	return lu, nil
}
