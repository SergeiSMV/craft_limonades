package repository

import (
	"context"
	"fmt"

	"craftwms/internal/model"
)

// Стеллажи и настройки этикеток ячеек (ADHOC-57). Живут на CellRepository: стеллаж - часть
// раскладки ячеек склада, отдельный репозиторий дробил бы одну транзакцию импорта на два.

// UpsertRack заводит или находит стеллаж склада по коду и возвращает его id и признак «создан».
// Стеллаж - только группировка ячеек: своих настроек у него нет (галочка карточки - у ячейки).
func (r *CellRepository) UpsertRack(ctx context.Context, q Querier, warehouseID, code string) (string, bool, error) {
	var id string
	var created bool
	// DO UPDATE, а не DO NOTHING: только он возвращает строку существующего стеллажа.
	// (xmax = 0) - строка вставлена сейчас.
	err := q.QueryRow(ctx, `
		INSERT INTO racks (warehouse_id, code)
		VALUES ($1::uuid, $2)
		ON CONFLICT (warehouse_id, code) DO UPDATE SET code = EXCLUDED.code
		RETURNING id::text, (xmax = 0)`, warehouseID, code).Scan(&id, &created)
	if err != nil {
		return "", false, fmt.Errorf("стеллаж %q: %w", code, err)
	}
	return id, created, nil
}

// UpsertSetup заводит или обновляет ячейку по (warehouse_id, address) вместе со стеллажом и
// настройками этикетки - строка файла ячеек. Возвращает created=true для новой ячейки.
// Повторная загрузка того же файла не двоит ячейки и приводит настройки к файлу.
//
// sideCard nil - галочка карточки не задана файлом: у существующей ячейки не меняется, у новой
// false. Ячейка без стеллажа на карточку не попадает - её side_card всегда false.
//
// Адрес на «-Н-П» - напольное хранение (ADHOC-61): признак ставится по адресу, стеллажа у такой
// ячейки нет - пол у стеллажа на карточку стойки не попадает.
func (r *CellRepository) UpsertSetup(ctx context.Context, q Querier, warehouseID string, rackID *string, c model.CellSetup, sideCard *bool) (bool, error) {
	floor := IsFloorStorageAddress(c.Address)
	if floor {
		rackID = nil
	}
	var created bool
	err := q.QueryRow(ctx, `
		INSERT INTO cells (warehouse_id, address, rack_id, is_floor, label_small, label_barcode, side_card,
		                   is_floor_storage)
		VALUES ($1::uuid, $2, $3::uuid, $4, $5, $6, $3::uuid IS NOT NULL AND COALESCE($7::boolean, false), $8)
		ON CONFLICT (warehouse_id, address) DO UPDATE
		   SET rack_id = EXCLUDED.rack_id, is_floor = EXCLUDED.is_floor,
		       label_small = EXCLUDED.label_small, label_barcode = EXCLUDED.label_barcode,
		       side_card = EXCLUDED.rack_id IS NOT NULL AND COALESCE($7::boolean, cells.side_card),
		       is_floor_storage = EXCLUDED.is_floor_storage
		RETURNING (xmax = 0)`,
		warehouseID, c.Address, rackID, c.IsFloor, c.LabelSmall, c.LabelBarcode, sideCard, floor).Scan(&created)
	if err != nil {
		return false, fmt.Errorf("ячейка %q: %w", c.Address, err)
	}
	return created, nil
}

// Setup возвращает ячейки склада со стеллажами и настройками этикеток и все стеллажи склада.
//
// Без пагинации: ячеек на складе сотни, а странице нужен весь набор - массовая отметка, счётчики
// фильтров и выгрузка в файл работают по всему складу. Служебные ячейки («ПРИЁМКА», «ОТГРУЗКА»)
// не входят: у них нет этикетки и нет места на стеллаже. Порядок задаёт сервис.
func (r *CellRepository) Setup(ctx context.Context, warehouseID string) ([]model.CellSetup, []model.Rack, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT c.id::text, c.address, r.id::text, r.code, c.is_floor, c.label_small, c.label_barcode,
		       c.side_card, c.is_floor_storage
		FROM cells c LEFT JOIN racks r ON r.id = c.rack_id
		WHERE c.warehouse_id = $1::uuid AND c.is_active AND NOT c.is_default AND NOT c.is_shipping`, warehouseID)
	if err != nil {
		return nil, nil, fmt.Errorf("ячейки склада: %w", err)
	}
	cells := make([]model.CellSetup, 0)
	for rows.Next() {
		var c model.CellSetup
		if err := rows.Scan(&c.ID, &c.Address, &c.RackID, &c.RackCode, &c.IsFloor, &c.LabelSmall, &c.LabelBarcode, &c.SideCard, &c.IsFloorStorage); err != nil {
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
		SELECT id::text, code FROM racks WHERE warehouse_id = $1::uuid`, warehouseID)
	if err != nil {
		return nil, nil, fmt.Errorf("стеллажи склада: %w", err)
	}
	defer rrows.Close()
	racks := make([]model.Rack, 0)
	for rrows.Next() {
		var rk model.Rack
		if err := rrows.Scan(&rk.ID, &rk.Code); err != nil {
			return nil, nil, fmt.Errorf("scan стеллажа: %w", err)
		}
		racks = append(racks, rk)
	}
	return cells, racks, rrows.Err()
}

// UpdateSettings меняет галочки у ячеек склада одним UPDATE в транзакции q.
//
// Как: сначала проверка, что все id - активные ячейки этого склада, кроме ячейки приёмки; иначе
// ErrForeignCells и ничего не меняется. Поле патча nil - колонка не трогается (COALESCE).
// Галочка карточки ставится только ячейкам со стеллажом: у ячейки без стеллажа карточки нет, её
// side_card остаётся false (снять можно любой). Счётчик - сколько строк реально изменилось:
// «Сохранить» без изменений не должен рапортовать о правке.
func (r *CellRepository) UpdateSettings(ctx context.Context, q Querier, warehouseID string, p model.CellSettingsPatch) (model.CellSettingsResult, error) {
	var res model.CellSettingsResult
	var found int
	err := q.QueryRow(ctx, `
		SELECT count(*) FROM cells
		WHERE id = ANY($1::uuid[]) AND warehouse_id = $2::uuid AND is_active AND NOT is_default AND NOT is_shipping`,
		p.CellIDs, warehouseID).Scan(&found)
	if err != nil {
		return res, fmt.Errorf("проверка ячеек: %w", err)
	}
	if found != len(p.CellIDs) {
		return res, model.ErrForeignCells
	}

	tag, err := q.Exec(ctx, `
		WITH v AS (
		    SELECT id,
		           COALESCE($2::boolean, label_small)   AS label_small,
		           COALESCE($3::boolean, is_floor)      AS is_floor,
		           COALESCE($4::boolean, label_barcode) AS label_barcode,
		           rack_id IS NOT NULL AND COALESCE($5::boolean, side_card) AS side_card
		    FROM cells WHERE id = ANY($1::uuid[])
		)
		UPDATE cells c SET
		    label_small = v.label_small, is_floor = v.is_floor,
		    label_barcode = v.label_barcode, side_card = v.side_card
		FROM v
		WHERE c.id = v.id
		  AND (c.label_small, c.is_floor, c.label_barcode, c.side_card) IS DISTINCT FROM
		      (v.label_small, v.is_floor, v.label_barcode, v.side_card)`,
		p.CellIDs, p.LabelSmall, p.IsFloor, p.LabelBarcode, p.SideCard)
	if err != nil {
		return res, fmt.Errorf("настройки ячеек: %w", err)
	}
	res.CellsUpdated = int(tag.RowsAffected())
	return res, nil
}
