package repository

import (
	"context"
	"errors"
	"fmt"

	"craftwms/internal/model"
)

// Стеллажи и настройки этикеток ячеек (ADHOC-57). Живут на CellRepository: стеллаж — часть
// раскладки ячеек склада, отдельный репозиторий дробил бы одну транзакцию импорта на два.

// ErrForeignCells — в патче есть ячейки не этого склада, неактивные, ячейка приёмки или
// несуществующие: менять такие нельзя, и тихо пропускать их тоже нельзя.
var ErrForeignCells = errors.New("ячейки не найдены на складе")

// UpsertRack заводит или находит стеллаж склада по коду и возвращает его id и признак «создан».
// sideCard nil — признак карточки не трогается (стеллаж назван только в листе cells), у нового
// стеллажа тогда false.
func (r *CellRepository) UpsertRack(ctx context.Context, q Querier, warehouseID, code string, sideCard *bool) (string, bool, error) {
	var id string
	var created bool
	// DO UPDATE, а не DO NOTHING: только он возвращает строку существующего стеллажа.
	// (xmax = 0) — строка вставлена сейчас.
	err := q.QueryRow(ctx, `
		INSERT INTO racks (warehouse_id, code, side_card)
		VALUES ($1::uuid, $2, COALESCE($3::boolean, false))
		ON CONFLICT (warehouse_id, code) DO UPDATE
		   SET side_card = COALESCE($3::boolean, racks.side_card)
		RETURNING id::text, (xmax = 0)`, warehouseID, code, sideCard).Scan(&id, &created)
	if err != nil {
		return "", false, fmt.Errorf("стеллаж %q: %w", code, err)
	}
	return id, created, nil
}

// UpsertSetup заводит или обновляет ячейку по (warehouse_id, address) вместе со стеллажом и
// настройками этикетки — строка файла ячеек. Возвращает created=true для новой ячейки.
// Повторная загрузка того же файла не двоит ячейки и приводит настройки к файлу.
func (r *CellRepository) UpsertSetup(ctx context.Context, q Querier, warehouseID string, rackID *string, c model.CellSetup) (bool, error) {
	var created bool
	err := q.QueryRow(ctx, `
		INSERT INTO cells (warehouse_id, address, rack_id, is_floor, label_small, label_barcode)
		VALUES ($1::uuid, $2, $3::uuid, $4, $5, $6)
		ON CONFLICT (warehouse_id, address) DO UPDATE
		   SET rack_id = EXCLUDED.rack_id, is_floor = EXCLUDED.is_floor,
		       label_small = EXCLUDED.label_small, label_barcode = EXCLUDED.label_barcode
		RETURNING (xmax = 0)`,
		warehouseID, c.Address, rackID, c.IsFloor, c.LabelSmall, c.LabelBarcode).Scan(&created)
	if err != nil {
		return false, fmt.Errorf("ячейка %q: %w", c.Address, err)
	}
	return created, nil
}

// Setup возвращает ячейки склада со стеллажами и настройками этикеток и все стеллажи склада.
//
// Без пагинации: ячеек на складе сотни, а странице нужен весь набор — массовая отметка, счётчики
// фильтров и выгрузка в файл работают по всему складу. Ячейка приёмки («С-Н-П») не входит: у неё
// нет этикетки (адрес кириллицей Code128 не кодирует) и нет места на стеллаже. Порядок задаёт сервис.
func (r *CellRepository) Setup(ctx context.Context, warehouseID string) ([]model.CellSetup, []model.Rack, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT c.id::text, c.address, r.id::text, r.code, c.is_floor, c.label_small, c.label_barcode
		FROM cells c LEFT JOIN racks r ON r.id = c.rack_id
		WHERE c.warehouse_id = $1::uuid AND c.is_active AND NOT c.is_default`, warehouseID)
	if err != nil {
		return nil, nil, fmt.Errorf("ячейки склада: %w", err)
	}
	cells := make([]model.CellSetup, 0)
	for rows.Next() {
		var c model.CellSetup
		if err := rows.Scan(&c.ID, &c.Address, &c.RackID, &c.RackCode, &c.IsFloor, &c.LabelSmall, &c.LabelBarcode); err != nil {
			rows.Close()
			return nil, nil, fmt.Errorf("scan ячейки: %w", err)
		}
		cells = append(cells, c)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, nil, err
	}

	rrows, err := r.pool.Query(ctx, `
		SELECT id::text, code, side_card FROM racks WHERE warehouse_id = $1::uuid`, warehouseID)
	if err != nil {
		return nil, nil, fmt.Errorf("стеллажи склада: %w", err)
	}
	defer rrows.Close()
	racks := make([]model.Rack, 0)
	for rrows.Next() {
		var rk model.Rack
		if err := rrows.Scan(&rk.ID, &rk.Code, &rk.SideCard); err != nil {
			return nil, nil, fmt.Errorf("scan стеллажа: %w", err)
		}
		racks = append(racks, rk)
	}
	return cells, racks, rrows.Err()
}

// UpdateSettings меняет галочки у ячеек склада и признак карточки у их стеллажей — в транзакции q.
//
// Как: сначала проверка, что все id — активные ячейки этого склада, кроме ячейки приёмки; иначе
// ErrForeignCells и ничего не меняется. Поле патча nil — колонка не трогается (COALESCE). Карточка
// ставится стеллажам выбранных ячеек; ячейки без стеллажа на неё не влияют. Счётчики — сколько
// строк реально изменилось: «Сохранить» без изменений не должен рапортовать о правке.
func (r *CellRepository) UpdateSettings(ctx context.Context, q Querier, warehouseID string, p model.CellSettingsPatch) (model.CellSettingsResult, error) {
	var res model.CellSettingsResult
	var found int
	err := q.QueryRow(ctx, `
		SELECT count(*) FROM cells
		WHERE id = ANY($1::uuid[]) AND warehouse_id = $2::uuid AND is_active AND NOT is_default`,
		p.CellIDs, warehouseID).Scan(&found)
	if err != nil {
		return res, fmt.Errorf("проверка ячеек: %w", err)
	}
	if found != len(p.CellIDs) {
		return res, ErrForeignCells
	}

	if p.LabelSmall != nil || p.IsFloor != nil || p.LabelBarcode != nil {
		tag, err := q.Exec(ctx, `
			UPDATE cells SET
			    label_small   = COALESCE($2::boolean, label_small),
			    is_floor      = COALESCE($3::boolean, is_floor),
			    label_barcode = COALESCE($4::boolean, label_barcode)
			WHERE id = ANY($1::uuid[])
			  AND (label_small, is_floor, label_barcode) IS DISTINCT FROM
			      (COALESCE($2::boolean, label_small), COALESCE($3::boolean, is_floor),
			       COALESCE($4::boolean, label_barcode))`,
			p.CellIDs, p.LabelSmall, p.IsFloor, p.LabelBarcode)
		if err != nil {
			return res, fmt.Errorf("настройки ячеек: %w", err)
		}
		res.CellsUpdated = int(tag.RowsAffected())
	}

	if p.SideCard != nil {
		tag, err := q.Exec(ctx, `
			UPDATE racks SET side_card = $2
			WHERE id IN (SELECT rack_id FROM cells WHERE id = ANY($1::uuid[]) AND rack_id IS NOT NULL)
			  AND side_card IS DISTINCT FROM $2`, p.CellIDs, *p.SideCard)
		if err != nil {
			return res, fmt.Errorf("карточки стеллажей: %w", err)
		}
		res.RacksUpdated = int(tag.RowsAffected())
	}
	return res, nil
}
