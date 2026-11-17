package repository

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/model"
)

// CellRepository - доступ к таблице cells (физические ячейки хранения) и стеллажам racks:
// импорт, чтение для ТСД и портала, настройки этикеток (ADHOC-57).
type CellRepository struct {
	pool *pgxpool.Pool
}

// NewCellRepository создаёт репозиторий ячеек.
func NewCellRepository(pool *pgxpool.Pool) *CellRepository {
	return &CellRepository{pool: pool}
}

// EnsureDefault гарантирует складу ячейку приёмки по умолчанию и возвращает её id.
//
// Зачем: приёмка не заставляет кладовщика выбирать место - короб уезжает в дефолтную ячейку,
// если он не сказал иного. Склад без такой ячейки означал бы, что приёмка на нём невозможна,
// поэтому её заводит не человек, а тот, кто заводит сам склад: сидер при развёртывании и импорт
// ячеек при появлении нового склада.
//
// Идемпотентно: ячейка с этим адресом уже есть - ей проставляется признак, второй не появляется.
// DO UPDATE, а не DO NOTHING: только он возвращает строку, а нам нужен id и в этом случае тоже.
func (r *CellRepository) EnsureDefault(ctx context.Context, q Querier, warehouseID string) (string, error) {
	// Ячейка приёмки уже есть - какой бы ни был её адрес, вторую не заводим: частичный
	// уникальный индекс допускает одну на склад, а переименованную искать по адресу нельзя.
	if id, err := defaultCellID(ctx, q, warehouseID); err == nil || !errors.Is(err, model.ErrNotFound) {
		return id, err
	}
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

// EnsureShipping гарантирует складу ячейку отгрузки («ОТГРУЗКА», P9-02) и возвращает её id.
//
// Зачем: «Завершить сборку» ставит короба заказа в ячейку отгрузки - склад без неё собрать заказ
// не даст. Как и ячейку приёмки, её заводит тот, кто заводит склад: сидер и импорт ячеек;
// складам, что были до P9-02, - миграция 45. Ищет по признаку: переименование не плодит вторую.
func (r *CellRepository) EnsureShipping(ctx context.Context, q Querier, warehouseID string) (string, error) {
	var id string
	err := q.QueryRow(ctx, `
		SELECT id::text FROM cells WHERE warehouse_id = $1::uuid AND is_shipping`, warehouseID).Scan(&id)
	if err == nil || !errors.Is(err, pgx.ErrNoRows) {
		return id, err
	}
	err = q.QueryRow(ctx, `
		INSERT INTO cells (warehouse_id, address, is_shipping)
		VALUES ($1::uuid, $2, true)
		ON CONFLICT (warehouse_id, address) DO UPDATE SET is_shipping = true, is_active = true
		RETURNING id::text`, warehouseID, model.ShippingCellAddress).Scan(&id)
	if err != nil {
		return "", fmt.Errorf("ячейка отгрузки склада %s: %w", warehouseID, err)
	}
	return id, nil
}

// DefaultID возвращает ячейку приёмки по умолчанию для склада или ErrNotFound.
//
// Ищет ПО ФЛАГУ, а не по адресу: «ПРИЁМКА» - имя ячейки, и переименование не должно ломать приёмку.
func (r *CellRepository) DefaultID(ctx context.Context, warehouseID string) (string, error) {
	return defaultCellID(ctx, r.pool, warehouseID)
}

// defaultCellID - поиск дефолтной ячейки на Querier, для применения приёмки из очереди (P4-09).
func defaultCellID(ctx context.Context, q Querier, warehouseID string) (string, error) {
	var id string
	err := q.QueryRow(ctx, `
		SELECT id::text FROM cells WHERE warehouse_id = $1::uuid AND is_default`, warehouseID).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", model.ErrNotFound
	}
	if err != nil {
		return "", fmt.Errorf("дефолтная ячейка склада %s: %w", warehouseID, err)
	}
	return id, nil
}
