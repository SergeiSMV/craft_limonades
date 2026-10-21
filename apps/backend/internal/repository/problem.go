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
	// ErrSystemInternalWarehouse — склад системный (возврат поставщику, P6-07-3): на него и с него
	// переводит только решение офиса; скрыть и удалить его нельзя.
	ErrSystemInternalWarehouse = errors.New("system internal warehouse is managed by the program")
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

// guardProblemPlace — ячейка склада документа, не ячейка приёмки, товар не числится уже
// на складе назначения и не лежит на системном складе.
func guardProblemPlace(ctx context.Context, q Querier, cell, fromIwh string, in ProblemSubmitInput) error {
	if fromIwh == in.ToInternalWarehouseID {
		return ErrSameInternalWarehouse
	}
	if err := guardNotSystemSource(ctx, q, fromIwh); err != nil {
		return err
	}
	if err := guardCellOfWarehouse(ctx, q, cell, in.WarehouseID); err != nil {
		return err
	}
	return guardNotReceivingCell(ctx, q, cell)
}

// guardActiveInternalWarehouse — склад назначения существует, не скрыт и не системный:
// на системный склад (возврат поставщику) товар переводит только решение офиса (P6-07-3).
func guardActiveInternalWarehouse(ctx context.Context, q Querier, id string) error {
	var active, system bool
	err := q.QueryRow(ctx, `
		SELECT is_active, system_role IS NOT NULL FROM internal_warehouses WHERE id = $1::uuid`,
		id).Scan(&active, &system)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !active) {
		return ErrUnknownInternalWarehouse
	}
	if err != nil {
		return fmt.Errorf("проверить внутренний склад: %w", err)
	}
	if system {
		return ErrSystemInternalWarehouse
	}
	return nil
}

// guardNotSystemSource — товар на системном складе уже в задании возврата: пометить его
// заново значило бы увести из-под задания (P6-07-3).
func guardNotSystemSource(ctx context.Context, q Querier, iwh string) error {
	var system bool
	if err := q.QueryRow(ctx, `
		SELECT system_role IS NOT NULL FROM internal_warehouses WHERE id = $1::uuid`,
		iwh).Scan(&system); err != nil {
		return fmt.Errorf("проверить склад-источник: %w", err)
	}
	if system {
		return ErrSystemInternalWarehouse
	}
	return nil
}

// Ошибки справочника внутренних складов (ADHOC-29).
var (
	// ErrInternalWarehouseExists — склад с таким кодом уже есть.
	ErrInternalWarehouseExists = errors.New("internal warehouse code already exists")
	// ErrDefaultInternalWarehouse — склад по умолчанию нельзя скрыть или удалить: приходовать
	// было бы некуда.
	ErrDefaultInternalWarehouse = errors.New("default internal warehouse cannot be hidden or deleted")
	// ErrInternalWarehouseInUse — на складе есть остаток или история: удалить нельзя, только
	// скрыть.
	ErrInternalWarehouseInUse = errors.New("internal warehouse has stock or history")
)

// InternalWarehouseRepository — справочник внутренних складов (P6-07-1, ADHOC-29): чтение для
// ТСД и портала, ведение — из портала.
type InternalWarehouseRepository struct {
	pool *pgxpool.Pool
}

// NewInternalWarehouseRepository создаёт репозиторий внутренних складов.
func NewInternalWarehouseRepository(pool *pgxpool.Pool) *InternalWarehouseRepository {
	return &InternalWarehouseRepository{pool: pool}
}

// internalWarehouseSelect — склад с признаком «в деле»: есть строка остатка (даже нулевая —
// это история), короб этого склада или запись проблемы. Внешние ключи этих таблиц и так не
// дадут его удалить; признак нужен порталу, чтобы не предлагать удаление заведомо зря.
const internalWarehouseSelect = `
	SELECT w.id::text, w.code, w.name, w.is_default, w.is_active, COALESCE(w.system_role, ''),
	       EXISTS (SELECT 1 FROM stock s WHERE s.internal_warehouse_id = w.id)
	       OR EXISTS (SELECT 1 FROM load_units lu WHERE lu.internal_warehouse_id = w.id)
	       OR EXISTS (SELECT 1 FROM warehouse_problems p
	                  WHERE w.id IN (p.from_internal_warehouse_id, p.to_internal_warehouse_id))
	       OR EXISTS (SELECT 1 FROM movement_lines l WHERE l.internal_warehouse_id = w.id)
	FROM internal_warehouses w`

func scanInternalWarehouse(row pgx.Row) (model.InternalWarehouse, error) {
	var w model.InternalWarehouse
	err := row.Scan(&w.ID, &w.Code, &w.Name, &w.IsDefault, &w.IsActive, &w.SystemRole, &w.InUse)
	return w, err
}

// All — все склады, и скрытые: по умолчанию первым, дальше действующие, по имени. Скрытые
// нужны и ТСД — их остаток всё ещё лежит в ячейках и должен быть подписан.
func (r *InternalWarehouseRepository) All(ctx context.Context) ([]model.InternalWarehouse, error) {
	rows, err := r.pool.Query(ctx, internalWarehouseSelect+`
		ORDER BY w.is_default DESC, w.is_active DESC, w.name`)
	if err != nil {
		return nil, fmt.Errorf("внутренние склады: %w", err)
	}
	defer rows.Close()
	out := []model.InternalWarehouse{}
	for rows.Next() {
		w, err := scanInternalWarehouse(rows)
		if err != nil {
			return nil, fmt.Errorf("разобрать внутренний склад: %w", err)
		}
		out = append(out, w)
	}
	return out, rows.Err()
}

// Create заводит склад. Повтор кода — ErrInternalWarehouseExists.
func (r *InternalWarehouseRepository) Create(ctx context.Context, code, name string) (model.InternalWarehouse, error) {
	var id string
	err := r.pool.QueryRow(ctx, `
		INSERT INTO internal_warehouses (code, name) VALUES ($1, $2) RETURNING id::text`,
		code, name).Scan(&id)
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		return model.InternalWarehouse{}, ErrInternalWarehouseExists
	}
	if err != nil {
		return model.InternalWarehouse{}, fmt.Errorf("завести внутренний склад: %w", err)
	}
	return r.byID(ctx, id)
}

// Update переименовывает склад и (или) скрывает его или возвращает в выбор. nil — поле не
// меняется. Склад по умолчанию не скрывается.
func (r *InternalWarehouseRepository) Update(ctx context.Context, id string, name *string, active *bool) (model.InternalWarehouse, error) {
	current, err := r.byID(ctx, id)
	if err != nil {
		return model.InternalWarehouse{}, err
	}
	if current.IsDefault && active != nil && !*active {
		return model.InternalWarehouse{}, ErrDefaultInternalWarehouse
	}
	if current.SystemRole != "" && active != nil && !*active {
		return model.InternalWarehouse{}, ErrSystemInternalWarehouse
	}
	if _, err := r.pool.Exec(ctx, `
		UPDATE internal_warehouses
		SET name = COALESCE($2, name), is_active = COALESCE($3, is_active)
		WHERE id = $1::uuid`, id, name, active); err != nil {
		return model.InternalWarehouse{}, fmt.Errorf("изменить внутренний склад: %w", err)
	}
	return r.byID(ctx, id)
}

// Delete удаляет склад, у которого нет ни остатка, ни истории. Склад по умолчанию не
// удаляется; склад «в деле» — ErrInternalWarehouseInUse (его скрывают).
func (r *InternalWarehouseRepository) Delete(ctx context.Context, id string) error {
	current, err := r.byID(ctx, id)
	if err != nil {
		return err
	}
	if current.IsDefault {
		return ErrDefaultInternalWarehouse
	}
	if current.SystemRole != "" {
		return ErrSystemInternalWarehouse
	}
	if current.InUse {
		return ErrInternalWarehouseInUse
	}
	_, err = r.pool.Exec(ctx, `DELETE FROM internal_warehouses WHERE id = $1::uuid`, id)
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23503" {
		// Ссылка появилась между проверкой и удалением — тот же отказ.
		return ErrInternalWarehouseInUse
	}
	if err != nil {
		return fmt.Errorf("удалить внутренний склад: %w", err)
	}
	return nil
}

func (r *InternalWarehouseRepository) byID(ctx context.Context, id string) (model.InternalWarehouse, error) {
	w, err := scanInternalWarehouse(r.pool.QueryRow(ctx, internalWarehouseSelect+` WHERE w.id = $1::uuid`, id))
	if errors.Is(err, pgx.ErrNoRows) {
		return model.InternalWarehouse{}, ErrUnknownInternalWarehouse
	}
	if err != nil {
		return model.InternalWarehouse{}, fmt.Errorf("внутренний склад: %w", err)
	}
	return w, nil
}
