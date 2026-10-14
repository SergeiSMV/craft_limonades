package repository

import (
	"context"
	"errors"
	"fmt"
	"slices"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
)

// Ошибки пометки товара другим внутренним складом (P6-07-1). Все — отказ по существу.
var (
	// ErrProblemPosted — проблема с этим идентификатором уже зафиксирована.
	ErrProblemPosted = errors.New("problem already posted")
	// ErrEmptyProblem — в проблеме нет ни короба, ни товара с одним источником.
	ErrEmptyProblem = errors.New("problem must have a load unit or goods from a cell or a load unit")
	// ErrUnknownReason — причины нет в списке.
	ErrUnknownReason = errors.New("unknown problem reason")
	// ErrUnknownInternalWarehouse — склада назначения нет или он скрыт.
	ErrUnknownInternalWarehouse = errors.New("unknown or inactive internal warehouse")
	// ErrSameInternalWarehouse — товар уже числится на складе назначения.
	ErrSameInternalWarehouse = errors.New("goods already belong to the target internal warehouse")
)

// ProblemSubmitInput — проблема склада, собранная устройством (P6-07-1).
//
// Что помечено — ровно одно: короб целиком (LoadUnitID) ЛИБО товар партии с количеством —
// из россыпи ячейки (CellID; склад россыпи — FromInternalWarehouseID, пусто — по умолчанию)
// или из короба (FromLoadUnitID; склад — короба). Товар из короба вынимается в россыпь
// склада назначения той же ячейки.
type ProblemSubmitInput struct {
	ProblemID   string
	WarehouseID string
	CreatedBy   string

	LoadUnitID string

	GoodID                  string
	ProductionDate          string // ISO 'YYYY-MM-DD'
	Qty                     decimal.Decimal
	CellID                  string
	FromLoadUnitID          string
	FromInternalWarehouseID string

	ToInternalWarehouseID string
	Reason                string
	Comment               string
	Mark                  string
}

// problemSubmit фиксирует проблему и переводит остаток на склад назначения (P6-07-1).
//
// Что: короб целиком меняет склад вместе с остатком своего состава; товар переходит строкой
//
//	нового склада в той же ячейке (из короба — вынимается в россыпь). Количество не теряется:
//	перевод — общий примитив transferStock между строками одной ячейки.
//
// Зачем одной транзакцией: запись проблемы и перевод остатка — один факт; офис решает судьбу
//
//	товара по записи (P6-07-3), и записи без перевода (или наоборот) быть не должно.
//
// Ячейка приёмки отклоняется, как в движении: её содержимое разносит задание на размещение,
// и брак под заданием оставил бы задание с недостающим «Основным» товаром.
func problemSubmit(ctx context.Context, q Querier, in ProblemSubmitInput) error {
	if !slices.Contains(model.ProblemReasons, in.Reason) {
		return ErrUnknownReason
	}
	isBox := in.LoadUnitID != ""
	isGoods := in.GoodID != ""
	if isBox == isGoods || (isGoods && (in.CellID == "") == (in.FromLoadUnitID == "")) {
		return ErrEmptyProblem
	}
	if isGoods && !in.Qty.IsPositive() {
		return ErrMovementQty
	}
	if err := guardActiveInternalWarehouse(ctx, q, in.ToInternalWarehouseID); err != nil {
		return err
	}

	var row problemRow
	var err error
	switch {
	case isBox:
		row, err = problemLoadUnit(ctx, q, in)
	case in.FromLoadUnitID != "":
		row, err = problemFromLoadUnit(ctx, q, in)
	default:
		row, err = problemLoose(ctx, q, in)
	}
	if err != nil {
		return err
	}

	if _, err := q.Exec(ctx, `
		INSERT INTO warehouse_problems
			(id, warehouse_id, cell_id, load_unit_id, good_id, batch_id, qty, from_load_unit_id,
			 from_internal_warehouse_id, to_internal_warehouse_id, reason, comment, mark, created_by)
		VALUES ($1::uuid, $2::uuid, $3::uuid, NULLIF($4, '')::uuid, NULLIF($5, '')::uuid,
		        NULLIF($6, '')::uuid, $7::numeric, NULLIF($8, '')::uuid,
		        $9::uuid, $10::uuid, $11, $12, NULLIF($13, ''), $14::uuid)`,
		in.ProblemID, in.WarehouseID, row.cell, in.LoadUnitID, in.GoodID, row.batch, row.qty,
		in.FromLoadUnitID, row.fromIwh, in.ToInternalWarehouseID, in.Reason, in.Comment, in.Mark,
		in.CreatedBy); err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return ErrProblemPosted
		}
		return fmt.Errorf("записать проблему склада: %w", err)
	}
	return nil
}

// problemRow — что о помеченном узнаёт запись: ячейка, склад-источник, партия и количество.
type problemRow struct {
	cell, fromIwh, batch string
	qty                  *string
}

// problemLoadUnit переводит короб целиком: остаток его состава переходит строкой нового склада
// в той же ячейке, а склад короба меняется — дальше он переезжает новым складом.
func problemLoadUnit(ctx context.Context, q Querier, in ProblemSubmitInput) (problemRow, error) {
	boxes, err := lockPlacedLoadUnits(ctx, q, in.LoadUnitID)
	if err != nil {
		return problemRow{}, err
	}
	box := boxes[in.LoadUnitID]
	if err := guardProblemPlace(ctx, q, box.cell, box.iwh, in); err != nil {
		return problemRow{}, err
	}
	items, err := loadUnitStock(ctx, q, in.LoadUnitID)
	if err != nil {
		return problemRow{}, err
	}
	for _, c := range items {
		if err := transferStock(ctx, q,
			model.StockKey{CellID: box.cell, GoodID: c.good, BatchID: c.batch, InternalWarehouseID: box.iwh},
			model.StockKey{CellID: box.cell, GoodID: c.good, BatchID: c.batch, InternalWarehouseID: in.ToInternalWarehouseID},
			c.qty); err != nil {
			return problemRow{}, err
		}
	}
	if _, err := q.Exec(ctx, `UPDATE load_units SET internal_warehouse_id = $2::uuid WHERE id = $1::uuid`,
		in.LoadUnitID, in.ToInternalWarehouseID); err != nil {
		return problemRow{}, fmt.Errorf("сменить склад короба: %w", err)
	}
	return problemRow{cell: box.cell, fromIwh: box.iwh}, nil
}

// problemFromLoadUnit вынимает товар из короба в россыпь склада назначения той же ячейки:
// у короба одна метка на весь состав, поэтому часть короба помечается выниманием.
func problemFromLoadUnit(ctx context.Context, q Querier, in ProblemSubmitInput) (problemRow, error) {
	boxes, err := lockPlacedLoadUnits(ctx, q, in.FromLoadUnitID)
	if err != nil {
		return problemRow{}, err
	}
	box := boxes[in.FromLoadUnitID]
	if err := guardProblemPlace(ctx, q, box.cell, box.iwh, in); err != nil {
		return problemRow{}, err
	}
	batchID, err := existingBatch(ctx, q, in.GoodID, in.ProductionDate)
	if err != nil {
		return problemRow{}, err
	}
	if err := takeFromLoadUnit(ctx, q, in.FromLoadUnitID, in.GoodID, batchID, in.Qty); err != nil {
		return problemRow{}, err
	}
	return problemGoods(ctx, q, in, box.cell, box.iwh, batchID)
}

// problemLoose переводит россыпь ячейки — не больше, чем россыпи склада-источника лежит вне
// коробов этого склада.
func problemLoose(ctx context.Context, q Querier, in ProblemSubmitInput) (problemRow, error) {
	from := in.FromInternalWarehouseID
	if from == "" {
		var err error
		if from, err = defaultInternalWarehouse(ctx, q); err != nil {
			return problemRow{}, err
		}
	}
	if err := guardProblemPlace(ctx, q, in.CellID, from, in); err != nil {
		return problemRow{}, err
	}
	batchID, err := existingBatch(ctx, q, in.GoodID, in.ProductionDate)
	if err != nil {
		return problemRow{}, err
	}
	loose, err := looseQty(ctx, q, in.CellID, in.GoodID, batchID, from)
	if err != nil {
		return problemRow{}, err
	}
	if loose.LessThan(in.Qty) {
		return problemRow{}, ErrGoodsShort
	}
	return problemGoods(ctx, q, in, in.CellID, from, batchID)
}

// problemGoods переводит количество товара партии между складами в одной ячейке.
func problemGoods(ctx context.Context, q Querier, in ProblemSubmitInput, cell, fromIwh, batchID string) (problemRow, error) {
	if err := transferStock(ctx, q,
		model.StockKey{CellID: cell, GoodID: in.GoodID, BatchID: batchID, InternalWarehouseID: fromIwh},
		model.StockKey{CellID: cell, GoodID: in.GoodID, BatchID: batchID, InternalWarehouseID: in.ToInternalWarehouseID},
		in.Qty); err != nil {
		return problemRow{}, err
	}
	qty := in.Qty.String()
	return problemRow{cell: cell, fromIwh: fromIwh, batch: batchID, qty: &qty}, nil
}

// guardProblemPlace — ячейка склада документа, не ячейка приёмки, и товар не числится уже
// на складе назначения.
func guardProblemPlace(ctx context.Context, q Querier, cell, fromIwh string, in ProblemSubmitInput) error {
	if fromIwh == in.ToInternalWarehouseID {
		return ErrSameInternalWarehouse
	}
	if err := guardCellOfWarehouse(ctx, q, cell, in.WarehouseID); err != nil {
		return err
	}
	return guardNotReceivingCell(ctx, q, cell)
}

// guardActiveInternalWarehouse — склад назначения существует и не скрыт.
func guardActiveInternalWarehouse(ctx context.Context, q Querier, id string) error {
	var active bool
	err := q.QueryRow(ctx, `SELECT is_active FROM internal_warehouses WHERE id = $1::uuid`, id).Scan(&active)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !active) {
		return ErrUnknownInternalWarehouse
	}
	if err != nil {
		return fmt.Errorf("проверить внутренний склад: %w", err)
	}
	return nil
}

// InternalWarehouseRepository — справочник внутренних складов для ТСД (P6-07-1).
type InternalWarehouseRepository struct {
	pool *pgxpool.Pool
}

// NewInternalWarehouseRepository создаёт репозиторий внутренних складов.
func NewInternalWarehouseRepository(pool *pgxpool.Pool) *InternalWarehouseRepository {
	return &InternalWarehouseRepository{pool: pool}
}

// Active — внутренние склады для выбора на ТСД: по умолчанию первым, дальше по имени. Скрытые
// не показываются — на них нельзя пометить, но остаток на них сохраняется.
func (r *InternalWarehouseRepository) Active(ctx context.Context) ([]model.InternalWarehouse, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT id::text, code, name, is_default FROM internal_warehouses
		WHERE is_active ORDER BY is_default DESC, name`)
	if err != nil {
		return nil, fmt.Errorf("внутренние склады: %w", err)
	}
	defer rows.Close()
	out := []model.InternalWarehouse{}
	for rows.Next() {
		var w model.InternalWarehouse
		if err := rows.Scan(&w.ID, &w.Code, &w.Name, &w.IsDefault); err != nil {
			return nil, fmt.Errorf("разобрать внутренний склад: %w", err)
		}
		out = append(out, w)
	}
	return out, rows.Err()
}
