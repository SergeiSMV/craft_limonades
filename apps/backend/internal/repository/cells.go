package repository

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/model"
)

// CellRepository — доступ к таблице cells (физические ячейки хранения) и стеллажам racks:
// импорт, чтение для ТСД и портала, настройки этикеток (ADHOC-57).
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
//
// Дефолтная ячейка ИСКЛЮЧЕНА (решение заказчика: ШК у неё нет). Это не косметика: её адрес
// «С-Н-П» набран кириллицей, а Code128 её не кодирует — одна такая ячейка роняла бы печать
// этикеток ВСЕГО склада, а не только свою (P4-03).
func (r *CellRepository) LabelsByWarehouse(ctx context.Context, warehouseID string) ([]model.CellLabel, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT address, is_floor FROM cells
		WHERE warehouse_id = $1::uuid AND is_active = true AND NOT is_default`, warehouseID)
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

// EnsureDefault гарантирует складу ячейку приёмки по умолчанию и возвращает её id.
//
// Зачем: приёмка не заставляет кладовщика выбирать место — короб уезжает в дефолтную ячейку,
// если он не сказал иного. Склад без такой ячейки означал бы, что приёмка на нём невозможна,
// поэтому её заводит не человек, а тот, кто заводит сам склад: сидер при развёртывании и импорт
// ячеек при появлении нового склада.
//
// Идемпотентно: ячейка с этим адресом уже есть — ей проставляется признак, второй не появляется.
// DO UPDATE, а не DO NOTHING: только он возвращает строку, а нам нужен id и в этом случае тоже.
func (r *CellRepository) EnsureDefault(ctx context.Context, q Querier, warehouseID string) (string, error) {
	var id string
	err := q.QueryRow(ctx, `
		INSERT INTO cells (warehouse_id, address, is_default)
		VALUES ($1::uuid, $2, true)
		ON CONFLICT (warehouse_id, address) DO UPDATE SET is_default = true
		RETURNING id::text`, warehouseID, model.DefaultCellAddress).Scan(&id)
	if err != nil {
		return "", fmt.Errorf("дефолтная ячейка склада %s: %w", warehouseID, err)
	}
	return id, nil
}

// DefaultID возвращает ячейку приёмки по умолчанию для склада или ErrNotFound.
//
// Ищет ПО ФЛАГУ, а не по адресу: «С-Н-П» — имя ячейки, и переименование не должно ломать приёмку.
func (r *CellRepository) DefaultID(ctx context.Context, warehouseID string) (string, error) {
	return defaultCellID(ctx, r.pool, warehouseID)
}

// defaultCellID — поиск дефолтной ячейки на Querier, для применения приёмки из очереди (P4-09).
func defaultCellID(ctx context.Context, q Querier, warehouseID string) (string, error) {
	var id string
	err := q.QueryRow(ctx, `
		SELECT id::text FROM cells WHERE warehouse_id = $1::uuid AND is_default`, warehouseID).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", fmt.Errorf("дефолтная ячейка склада %s: %w", warehouseID, err)
	}
	return id, nil
}
