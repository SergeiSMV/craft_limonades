package repository

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"
)

// NomenclatureGroupRepository — доступ к дереву групп номенклатуры (импорт из 1С).
type NomenclatureGroupRepository struct {
	pool *pgxpool.Pool
}

// NewNomenclatureGroupRepository создаёт репозиторий групп номенклатуры.
func NewNomenclatureGroupRepository(pool *pgxpool.Pool) *NomenclatureGroupRepository {
	return &NomenclatureGroupRepository{pool: pool}
}

// Upsert заводит/обновляет группу по «Коду» из 1С (стабильный ключ) и возвращает её id.
// parentID — id родительской группы (nil для корня). Идемпотентно: повторный импорт не двоит.
func (r *NomenclatureGroupRepository) Upsert(ctx context.Context, q Querier, code, name string, parentID *string) (string, error) {
	var id string
	err := q.QueryRow(ctx, `
		INSERT INTO nomenclature_groups (code, name, parent_id)
		VALUES ($1, $2, $3::uuid)
		ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, parent_id = EXCLUDED.parent_id
		RETURNING id::text`, code, name, parentID).Scan(&id)
	if err != nil {
		return "", fmt.Errorf("upsert group %q: %w", code, err)
	}
	return id, nil
}

// SupplierRepository — доступ к справочнику поставщиков.
type SupplierRepository struct {
	pool *pgxpool.Pool
}

// NewSupplierRepository создаёт репозиторий поставщиков.
func NewSupplierRepository(pool *pgxpool.Pool) *SupplierRepository {
	return &SupplierRepository{pool: pool}
}

// Upsert заводит/возвращает поставщика по имени (дедуп по имени) и отдаёт его id.
func (r *SupplierRepository) Upsert(ctx context.Context, q Querier, name string) (string, error) {
	var id string
	// DO UPDATE (а не DO NOTHING), чтобы RETURNING вернул id и при конфликте.
	err := q.QueryRow(ctx, `
		INSERT INTO suppliers (name) VALUES ($1)
		ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name
		RETURNING id::text`, name).Scan(&id)
	if err != nil {
		return "", fmt.Errorf("upsert supplier %q: %w", name, err)
	}
	return id, nil
}
