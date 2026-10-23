package repository

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/model"
)

// CZMarkRepository — марки и агрегаты Честного знака на складе (CZ-03).
//
// Что: запись короба ЧЗ с составом, марок россыпью и чтение «где лежит марка», «что в коробе»,
// «что в упаковке ЧЗ». Каждая запись — и функция на Querier: приёмка (CZ-05) и движение
// (CZ-06) пишут марки в одной транзакции со своим документом и остатком.
type CZMarkRepository struct {
	pool *pgxpool.Pool
}

// NewCZMarkRepository создаёт репозиторий марок.
func NewCZMarkRepository(pool *pgxpool.Pool) *CZMarkRepository {
	return &CZMarkRepository{pool: pool}
}

// ReceiveBox сохраняет транспортный короб ЧЗ, его групповые упаковки и марки одной
// транзакцией: короб ЧЗ без части марок означал бы, что «что в коробе» отвечает неправду.
// ГЕ короба (box.LoadUnitID) должна уже существовать — её заводит приёмка.
func (r *CZMarkRepository) ReceiveBox(ctx context.Context, box model.CZAggregate, groups []model.CZAggregate, marks []model.CZMark) error {
	return WithinTx(ctx, r.pool, func(q Querier) error {
		if err := insertCZAggregate(ctx, q, box); err != nil {
			return err
		}
		for _, g := range groups {
			if err := insertCZAggregate(ctx, q, g); err != nil {
				return err
			}
		}
		return insertCZMarks(ctx, q, marks)
	})
}

// SaveMarks сохраняет марки одной транзакцией: все или ни одной.
func (r *CZMarkRepository) SaveMarks(ctx context.Context, marks []model.CZMark) error {
	return WithinTx(ctx, r.pool, func(q Querier) error { return insertCZMarks(ctx, q, marks) })
}

// insertCZAggregate заводит агрегат ЧЗ. Повтор кода или вторая ГЕ у короба — ErrCZAggregateExists:
// один короб ЧЗ принимают один раз.
func insertCZAggregate(ctx context.Context, q Querier, a model.CZAggregate) error {
	_, err := q.Exec(ctx, `
		INSERT INTO cz_aggregates (code, kind, parent_code, load_unit_id, opened_at)
		VALUES ($1, $2, NULLIF($3, ''), NULLIF($4, '')::uuid, $5)`,
		a.Code, a.Kind, a.ParentCode, a.LoadUnitID, a.OpenedAt)
	if err != nil {
		if isUniqueViolation(err) {
			return fmt.Errorf("%w: %s", model.ErrCZAggregateExists, a.Code)
		}
		return fmt.Errorf("агрегат ЧЗ %s: %w", a.Code, err)
	}
	return nil
}

// insertCZMarks заводит марки. Статус по умолчанию — на складе. Повтор КИ —
// ErrCZMarkExists с этим КИ: марка уникальна, и вызывающему нужно знать, какая именно.
func insertCZMarks(ctx context.Context, q Querier, marks []model.CZMark) error {
	for _, m := range marks {
		status := m.Status
		if status == "" {
			status = model.CZMarkInStock
		}
		_, err := q.Exec(ctx, `
			INSERT INTO cz_marks (cis, good_id, batch_id, status, load_unit_id, cell_id,
			                      internal_warehouse_id, aggregate_code)
			VALUES ($1, $2::uuid, $3::uuid, $4, NULLIF($5, '')::uuid, NULLIF($6, '')::uuid,
			        NULLIF($7, '')::uuid, NULLIF($8, ''))`,
			m.CIS, m.GoodID, m.BatchID, status, m.LoadUnitID, m.CellID, m.InternalWarehouseID, m.AggregateCode)
		if err != nil {
			if isUniqueViolation(err) {
				return fmt.Errorf("%w: %s", model.ErrCZMarkExists, m.CIS)
			}
			return fmt.Errorf("марка %s: %w", m.CIS, err)
		}
	}
	return nil
}

// isUniqueViolation — нарушение уникальности (код Postgres 23505).
func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}

// LoadUnitByCZCode — ГЕ транспортного короба ЧЗ по его коду (`00`+SSCC со штрихкода GS1-128):
// так скан короба на ТСД находит ГЕ без своего QR-ярлыка.
// ErrCZAggregateNotFound — кода нет или это не короб с ГЕ.
func (r *CZMarkRepository) LoadUnitByCZCode(ctx context.Context, code string) (string, error) {
	var id string
	err := r.pool.QueryRow(ctx, `
		SELECT load_unit_id::text FROM cz_aggregates
		WHERE code = $1 AND load_unit_id IS NOT NULL`, code).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", fmt.Errorf("%w: %s", model.ErrCZAggregateNotFound, code)
	}
	if err != nil {
		return "", fmt.Errorf("ГЕ по коду ЧЗ: %w", err)
	}
	return id, nil
}

// czMarkSelect — чтение марки с местом её короба. Место короба берётся из load_units: у марки
// оно не хранится (место ГЕ — только load_units.cell_id).
const czMarkSelect = `
	SELECT m.cis, m.gtin, m.good_id::text, m.batch_id::text, m.status,
	       COALESCE(m.load_unit_id::text, ''), COALESCE(m.cell_id::text, ''),
	       COALESCE(m.internal_warehouse_id::text, ''), COALESCE(m.aggregate_code, ''),
	       COALESCE(lu.cell_id::text, '')
	FROM cz_marks m
	LEFT JOIN load_units lu ON lu.id = m.load_unit_id`

// scanCZMark читает строку czMarkSelect.
func scanCZMark(row pgx.Row) (model.CZMark, error) {
	var m model.CZMark
	err := row.Scan(&m.CIS, &m.GTIN, &m.GoodID, &m.BatchID, &m.Status,
		&m.LoadUnitID, &m.CellID, &m.InternalWarehouseID, &m.AggregateCode, &m.LoadUnitCellID)
	return m, err
}

// MarkByCIS — марка по КИ: товар, партия, статус и где лежит.
func (r *CZMarkRepository) MarkByCIS(ctx context.Context, cis string) (model.CZMark, error) {
	m, err := scanCZMark(r.pool.QueryRow(ctx, czMarkSelect+` WHERE m.cis = $1`, cis))
	if errors.Is(err, pgx.ErrNoRows) {
		return model.CZMark{}, fmt.Errorf("%w: %s", model.ErrCZMarkNotFound, cis)
	}
	if err != nil {
		return model.CZMark{}, fmt.Errorf("марка по КИ: %w", err)
	}
	return m, nil
}

// MarksOfLoadUnit — марки, лежащие в ГЕ.
func (r *CZMarkRepository) MarksOfLoadUnit(ctx context.Context, loadUnitID string) ([]model.CZMark, error) {
	return queryCZMarks(ctx, r.pool, czMarkSelect+` WHERE m.load_unit_id = $1::uuid ORDER BY m.cis`, loadUnitID)
}

// LooseMarksOfCell — марки россыпью в ячейке (без коробов: их марки — у ГЕ).
func (r *CZMarkRepository) LooseMarksOfCell(ctx context.Context, cellID string) ([]model.CZMark, error) {
	return queryCZMarks(ctx, r.pool, czMarkSelect+` WHERE m.cell_id = $1::uuid ORDER BY m.cis`, cellID)
}

// queryCZMarks — список марок по запросу на базе czMarkSelect.
func queryCZMarks(ctx context.Context, q Querier, sql string, args ...any) ([]model.CZMark, error) {
	rows, err := q.Query(ctx, sql, args...)
	if err != nil {
		return nil, fmt.Errorf("марки: %w", err)
	}
	defer rows.Close()
	out := []model.CZMark{}
	for rows.Next() {
		m, err := scanCZMark(rows)
		if err != nil {
			return nil, fmt.Errorf("марка: %w", err)
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// AggregateContents — агрегат ЧЗ и его состав по ЧЗ: вложенные упаковки и марки, которые в нём
// числятся. Это состав по документам ЧЗ, а не по месту: изъятая из короба марка остаётся в
// составе, пока ЧЗ не расформировал упаковку, — короб при этом помечен вскрытым (CZ-06).
func (r *CZMarkRepository) AggregateContents(ctx context.Context, code string) (model.CZAggregateContents, error) {
	var out model.CZAggregateContents
	agg, err := scanCZAggregate(r.pool.QueryRow(ctx, czAggregateSelect+` WHERE code = $1`, code))
	if errors.Is(err, pgx.ErrNoRows) {
		return out, fmt.Errorf("%w: %s", model.ErrCZAggregateNotFound, code)
	}
	if err != nil {
		return out, fmt.Errorf("агрегат ЧЗ: %w", err)
	}
	out.Aggregate = agg

	rows, err := r.pool.Query(ctx, czAggregateSelect+` WHERE parent_code = $1 ORDER BY code`, code)
	if err != nil {
		return out, fmt.Errorf("вложенные упаковки: %w", err)
	}
	defer rows.Close()
	out.Groups = []model.CZAggregate{}
	for rows.Next() {
		g, err := scanCZAggregate(rows)
		if err != nil {
			return out, fmt.Errorf("упаковка: %w", err)
		}
		out.Groups = append(out.Groups, g)
	}
	if err := rows.Err(); err != nil {
		return out, err
	}

	out.Marks, err = queryCZMarks(ctx, r.pool, czMarkSelect+` WHERE m.aggregate_code = $1 ORDER BY m.cis`, code)
	return out, err
}

// czAggregateSelect — чтение агрегата ЧЗ.
const czAggregateSelect = `
	SELECT code, kind, COALESCE(parent_code, ''), COALESCE(load_unit_id::text, ''), opened_at
	FROM cz_aggregates`

// scanCZAggregate читает строку czAggregateSelect.
func scanCZAggregate(row pgx.Row) (model.CZAggregate, error) {
	var a model.CZAggregate
	var opened *time.Time
	if err := row.Scan(&a.Code, &a.Kind, &a.ParentCode, &a.LoadUnitID, &opened); err != nil {
		return a, err
	}
	a.OpenedAt = opened
	return a, nil
}

// GoodByGTIN — товар справочника по GTIN марки.
//
// Как: GTIN-14 единицы — это её EAN-13 с ведущим нулём (марка пива 04612728200172 ↔ ШК
// 4612728200172), поэтому ищем в barcodes и полный GTIN, и его же без нуля. Совпадение по
// полному GTIN — первым. ErrCZUnknownGTIN — товара с таким ШК нет: марка «не того товара».
func (r *CZMarkRepository) GoodByGTIN(ctx context.Context, gtin string) (string, error) {
	return goodByGTIN(ctx, r.pool, gtin)
}

// goodByGTIN — GoodByGTIN на Querier, для приёмки внутри транзакции (CZ-05).
func goodByGTIN(ctx context.Context, q Querier, gtin string) (string, error) {
	short := gtin
	if len(gtin) == 14 && gtin[0] == '0' {
		short = gtin[1:]
	}
	var id string
	err := q.QueryRow(ctx, `
		SELECT good_id::text FROM barcodes
		WHERE barcode IN ($1, $2)
		ORDER BY barcode = $1 DESC
		LIMIT 1`, gtin, short).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", fmt.Errorf("%w: %s", model.ErrCZUnknownGTIN, gtin)
	}
	if err != nil {
		return "", fmt.Errorf("товар по GTIN: %w", err)
	}
	return id, nil
}
