package repository

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"craftwms/internal/model"
)

// Напольные ячейки (ADHOC-61): пол у стеллажа, адрес вида «D-Н-П». Ведутся вручную на странице
// «Ячейки» портала - в файле стеллажей rack_labels их обычно нет. Живут на CellRepository: это
// те же строки cells, что и ячейки стеллажей.

// Псевдонимы ошибок из model на время ADHOC-71 (долг 38): старые ссылки работают, errors.Is
// сравнивает тот же объект. Снимаются, когда все ссылки переведены на model.
var (
	ErrCellExists   = model.ErrCellExists
	ErrCellNotEmpty = model.ErrCellNotEmpty
)

// IsFloorStorageAddress - адрес напольной ячейки: оканчивается на «-Н-П» (ADHOC-61).
func IsFloorStorageAddress(address string) bool {
	return strings.HasSuffix(address, model.FloorStorageSuffix)
}

// CreateFloorCell заводит напольную ячейку склада и возвращает её id.
//
// Как: адрес уже есть у неактивной (удалённой) ячейки - она возвращается в работу напольной:
// на неё ссылается история, вторую строку с тем же адресом уникальный ключ не даст. Адрес у
// активной ячейки - ErrCellExists. Без стеллажа и карточки: пол на карточку стойки не попадает.
func (r *CellRepository) CreateFloorCell(ctx context.Context, q Querier, warehouseID, address string) (string, error) {
	var id string
	err := q.QueryRow(ctx, `
		INSERT INTO cells (warehouse_id, address, is_floor_storage)
		VALUES ($1::uuid, $2, true)
		ON CONFLICT (warehouse_id, address) DO UPDATE
		   SET is_active = true, is_floor_storage = true, rack_id = NULL, side_card = false
		   WHERE NOT cells.is_active
		RETURNING id::text`, warehouseID, address).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrCellExists
	}
	if err != nil {
		return "", fmt.Errorf("напольная ячейка %q: %w", address, err)
	}
	return id, nil
}

// RenameFloorCell меняет адрес активной напольной ячейки склада.
//
// Ячейка не найдена среди напольных этого склада - ErrNotFound (ячейку стеллажа или приёмки так
// не переименовать). Адрес занят - ErrCellExists. Остаток и история ссылаются на id, адрес
// меняется вместе с ними.
func (r *CellRepository) RenameFloorCell(ctx context.Context, q Querier, warehouseID, cellID, address string) error {
	tag, err := q.Exec(ctx, `
		UPDATE cells SET address = $3
		WHERE id = $1::uuid AND warehouse_id = $2::uuid AND is_active AND is_floor_storage`,
		cellID, warehouseID, address)
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		return ErrCellExists
	}
	if err != nil {
		return fmt.Errorf("переименовать ячейку: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// DeleteFloorCell убирает пустую напольную ячейку склада: is_active = false.
//
// Мягко, а не DELETE: на ячейку ссылаются строки приёмок, движений и пересчётов. Пустая - нет
// остатка с количеством и нет коробов, стоящих в ней; иначе ErrCellNotEmpty. Строка ячейки
// блокируется (FOR UPDATE) - параллельное движение в неё дождётся удаления. Не напольная или
// чужая ячейка - ErrNotFound.
func (r *CellRepository) DeleteFloorCell(ctx context.Context, q Querier, warehouseID, cellID string) error {
	var found bool
	err := q.QueryRow(ctx, `
		SELECT true FROM cells
		WHERE id = $1::uuid AND warehouse_id = $2::uuid AND is_active AND is_floor_storage
		FOR UPDATE`, cellID, warehouseID).Scan(&found)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return fmt.Errorf("найти ячейку: %w", err)
	}
	var busy bool
	if err := q.QueryRow(ctx, `
		SELECT EXISTS (SELECT 1 FROM stock WHERE cell_id = $1::uuid AND qty > 0)
		    OR EXISTS (SELECT 1 FROM load_units WHERE cell_id = $1::uuid)`, cellID).Scan(&busy); err != nil {
		return fmt.Errorf("проверить содержимое ячейки: %w", err)
	}
	if busy {
		return ErrCellNotEmpty
	}
	if _, err := q.Exec(ctx, `UPDATE cells SET is_active = false WHERE id = $1::uuid`, cellID); err != nil {
		return fmt.Errorf("удалить ячейку: %w", err)
	}
	return nil
}
