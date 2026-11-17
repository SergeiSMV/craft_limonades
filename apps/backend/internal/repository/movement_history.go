package repository

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
)

// MovementHistoryRepository - чтение истории перемещений для ТСД (ADHOC-28). Только чтение
// журнала P6-01: проводит движение operations, здесь его показывают.
type MovementHistoryRepository struct {
	pool *pgxpool.Pool
}

// NewMovementHistoryRepository создаёт репозиторий истории перемещений.
func NewMovementHistoryRepository(pool *pgxpool.Pool) *MovementHistoryRepository {
	return &MovementHistoryRepository{pool: pool}
}

// movementRecordSelect - шапка записи ленты: документ, кто двигал, сколько строк какого рода.
// Строки считаются подзапросами, а не группировкой с JOIN: фильтр и курсор остаются условиями
// по одной таблице movements и идут по индексу на posted_at.
const movementRecordSelect = `
	SELECT m.id::text, m.number, m.kind, m.posted_at, u.id::text, u.full_name,
	       (SELECT count(*) FROM movement_lines l WHERE l.movement_id = m.id AND l.load_unit_id IS NOT NULL),
	       (SELECT count(*) FROM movement_lines l WHERE l.movement_id = m.id AND l.good_id IS NOT NULL)
	FROM movements m
	JOIN users u ON u.id = m.created_by`

func scanMovementRecord(row pgx.Row) (model.MovementRecord, error) {
	var r model.MovementRecord
	err := row.Scan(&r.ID, &r.Number, &r.Kind, &r.PostedAt, &r.Executor.ID, &r.Executor.FullName, &r.LoadUnits, &r.Goods)
	return r, err
}

// List - страница ленты: свежие сверху, подгрузка курсором (posted_at, id).
//
// Курсор, а не смещение: перемещения, проведённые во время просмотра, не сдвигают уже
// загруженные страницы - тот же приём, что у ленты «Завершённые» заданий.
func (r *MovementHistoryRepository) List(ctx context.Context, f model.MovementHistoryFilter) ([]model.MovementRecord, error) {
	rows, err := r.pool.Query(ctx, movementRecordSelect+`
		WHERE ($1::timestamptz IS NULL OR m.posted_at >= $1)
		  AND ($2::timestamptz IS NULL OR m.posted_at <  $2)
		  AND ($3::text = '' OR m.created_by = NULLIF($3, '')::uuid)
		  AND ($4::timestamptz IS NULL OR (m.posted_at, m.id) < ($4, NULLIF($5, '')::uuid))
		ORDER BY m.posted_at DESC, m.id DESC
		LIMIT $6`,
		f.From, f.To, f.ExecutorID, f.BeforePostedAt, f.BeforeID, f.Limit)
	if err != nil {
		return nil, fmt.Errorf("история перемещений: %w", err)
	}
	defer rows.Close()
	out := []model.MovementRecord{}
	for rows.Next() {
		rec, err := scanMovementRecord(rows)
		if err != nil {
			return nil, fmt.Errorf("разобрать запись истории: %w", err)
		}
		out = append(out, rec)
	}
	return out, rows.Err()
}

// Executors - все, кто когда-либо перемещал: варианты фильтра ленты по исполнителю.
func (r *MovementHistoryRepository) Executors(ctx context.Context) ([]model.TaskUser, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT DISTINCT u.id::text, u.full_name
		FROM movements m JOIN users u ON u.id = m.created_by
		ORDER BY u.full_name`)
	if err != nil {
		return nil, fmt.Errorf("исполнители перемещений: %w", err)
	}
	defer rows.Close()
	out := []model.TaskUser{}
	for rows.Next() {
		var u model.TaskUser
		if err := rows.Scan(&u.ID, &u.FullName); err != nil {
			return nil, fmt.Errorf("разобрать исполнителя: %w", err)
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

// Get - запись со строками в порядке, в каком их провёл кладовщик.
//
// Адреса ячеек и товар подставляются из справочников на момент чтения: история - рабочий
// инструмент склада, а не документ для 1С, и замораживать её снимком незачем.
func (r *MovementHistoryRepository) Get(ctx context.Context, id string) (model.MovementRecordDetail, error) {
	rec, err := scanMovementRecord(r.pool.QueryRow(ctx, movementRecordSelect+` WHERE m.id = $1::uuid`, id))
	if errors.Is(err, pgx.ErrNoRows) {
		return model.MovementRecordDetail{}, model.ErrMovementNotFound
	}
	if err != nil {
		return model.MovementRecordDetail{}, fmt.Errorf("запись истории: %w", err)
	}

	rows, err := r.pool.Query(ctx, `
		SELECT l.load_unit_id::text, g.id::text, g.code, g.name, g.uom, b.production_date, l.qty::text,
		       l.from_cell_id::text, cf.address, l.from_load_unit_id::text,
		       l.to_cell_id::text, ct.address, l.to_load_unit_id::text
		FROM movement_lines l
		JOIN cells cf        ON cf.id = l.from_cell_id
		JOIN cells ct        ON ct.id = l.to_cell_id
		LEFT JOIN goods g    ON g.id = l.good_id
		LEFT JOIN batches b  ON b.id = l.batch_id
		WHERE l.movement_id = $1::uuid
		ORDER BY l.line_no`, id)
	if err != nil {
		return model.MovementRecordDetail{}, fmt.Errorf("строки перемещения: %w", err)
	}
	defer rows.Close()
	out := model.MovementRecordDetail{MovementRecord: rec, Lines: []model.MovementRecordLine{}}
	for rows.Next() {
		var l model.MovementRecordLine
		var qty *string
		if err := rows.Scan(&l.LoadUnitID, &l.GoodID, &l.GoodCode, &l.GoodName, &l.Uom, &l.ProductionDate, &qty,
			&l.FromCellID, &l.FromCellAddress, &l.FromLoadUnitID,
			&l.ToCellID, &l.ToCellAddress, &l.ToLoadUnitID); err != nil {
			return model.MovementRecordDetail{}, fmt.Errorf("разобрать строку перемещения: %w", err)
		}
		if qty != nil {
			d, err := decimal.NewFromString(*qty)
			if err != nil {
				return model.MovementRecordDetail{}, fmt.Errorf("количество строки перемещения: %w", err)
			}
			l.Qty = &d
		}
		out.Lines = append(out.Lines, l)
	}
	return out, rows.Err()
}
