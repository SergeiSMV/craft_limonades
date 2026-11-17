package repository

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
)

// czStockOfBarcode - сколько марок ЧЗ с GTIN этого ШК лежит на складе (ADHOC-53).
//
// GTIN-14 марки - это EAN-13 ШК с ведущим нулём (CZ-01), поэтому ШК сравнивается и как есть,
// и дополненным нулём до 14 знаков.
func czStockOfBarcode(ctx context.Context, q Querier, barcode string) (int, error) {
	var n int
	if err := q.QueryRow(ctx, `
		SELECT count(*) FROM cz_marks
		WHERE gtin IN ($1, lpad($1, 14, '0')) AND status = $2`,
		barcode, model.CZMarkInStock).Scan(&n); err != nil {
		return 0, fmt.Errorf("марки ЧЗ на складе по ШК: %w", err)
	}
	return n, nil
}

// guardBindMarks не даёт привязать ШК к товару, если марки этого GTIN на складе числятся за
// другим товаром (ADHOC-53): исправлять такое - перепривязкой с пересортом, не привязкой.
func guardBindMarks(ctx context.Context, q Querier, goodID, barcode string) error {
	var other bool
	if err := q.QueryRow(ctx, `
		SELECT EXISTS (SELECT 1 FROM cz_marks
		               WHERE gtin IN ($1, lpad($1, 14, '0')) AND status = $2 AND good_id <> $3::uuid)`,
		barcode, model.CZMarkInStock, goodID).Scan(&other); err != nil {
		return fmt.Errorf("марки ЧЗ другого товара по ШК: %w", err)
	}
	if other {
		return model.ErrBarcodeMarksOtherGood
	}
	return nil
}

// CZStockOfBarcode - сколько марок ЧЗ с этим ШК на складе: ТСД спрашивает перед отвязкой.
func (r *BarcodeRepository) CZStockOfBarcode(ctx context.Context, barcode string) (int, error) {
	return czStockOfBarcode(ctx, r.pool, barcode)
}

// regradeGroup - марки одного места и партии: что пересорт снимает с прежнего товара и кладёт
// на новый одной строкой остатка (и состава короба).
type regradeGroup struct {
	regradePlace
	marks []string
}

// regradePlace - ключ группы: короб или россыпь ячейки склада, товар и партия.
type regradePlace struct {
	loadUnit, cell, iwh, good, batch, date string
}

// Regrade перепривязывает ШК к другому товару и переводит на него марки ЧЗ этого GTIN со склада
// (ADHOC-53, решение 2026-10-28).
//
// Что: ШК уходит к новому товару; марки на складе, их остаток в ячейках и состав коробов - тоже,
//
//	в партию той же даты производства; заводится проблема «Пересорт» со строками и марками -
//	офис проводит её документом пересортицы 1С.
//
// Зачем одной транзакцией: ШК, марки и остаток - один факт «это товар Y»; порознь они дали бы
//
//	момент, в котором ШК уже за Y, а марки и остаток ещё за X, - ровно ту дыру, которую задача
//	закрывает.
//
// Как: строка ШК и марки блокируются (марки - в порядке КИ, как в moveMarks); отказ, если
//
//	марка в открытой проблеме или ждёт отгрузки возврата, если ячейка марки на пересчёте или
//	короб не размещён. Остаток меняется только примитивами removeStock/addStock.
func (r *BarcodeRepository) Regrade(ctx context.Context, in model.RegradeInput) (model.RegradeResult, error) {
	var out model.RegradeResult
	err := WithinTx(ctx, r.pool, func(q Querier) error {
		var from string
		err := q.QueryRow(ctx, `SELECT good_id::text FROM barcodes WHERE barcode = $1 FOR UPDATE`,
			in.Barcode).Scan(&from)
		if errors.Is(err, pgx.ErrNoRows) {
			return model.ErrRegradeNotBound
		}
		if err != nil {
			return fmt.Errorf("ШК под перепривязку: %w", err)
		}
		if from == in.GoodID {
			return model.ErrRegradeSameGood
		}
		// Новый товар - маркируемый: на нём теперь марки, как после привязки ШК из марки.
		tag, err := q.Exec(ctx, `UPDATE goods SET cz_marked = true WHERE id = $1::uuid`, in.GoodID)
		if err != nil {
			return fmt.Errorf("пометить товар маркируемым: %w", err)
		}
		if tag.RowsAffected() == 0 {
			return model.ErrGoodNotFound
		}

		groups, err := regradeGroups(ctx, q, in.Barcode)
		if err != nil {
			return err
		}
		if _, err := q.Exec(ctx, `UPDATE barcodes SET good_id = $2::uuid WHERE barcode = $1`,
			in.Barcode, in.GoodID); err != nil {
			return fmt.Errorf("перепривязать ШК: %w", err)
		}
		if len(groups) == 0 {
			return nil
		}
		out.ProblemID = uuid.NewString()
		out.Marks, err = regradeMarks(ctx, q, in, from, out.ProblemID, groups)
		return err
	})
	return out, err
}

// regradeGroups блокирует марки ШК на складе, проверяет, что их можно перевести, и сводит их по
// месту и партии.
func regradeGroups(ctx context.Context, q Querier, barcode string) ([]regradeGroup, error) {
	rows, err := q.Query(ctx, `
		SELECT m.cis, COALESCE(m.load_unit_id::text, ''),
		       COALESCE(m.cell_id, lu.cell_id)::text, COALESCE(m.internal_warehouse_id, lu.internal_warehouse_id)::text,
		       m.good_id::text, m.batch_id::text, to_char(b.production_date, 'YYYY-MM-DD'),
		       COALESCE(p.status = 'open' OR (p.decision = 'supplier_return' AND p.shipment_id IS NULL), false)
		FROM cz_marks m
		JOIN batches b ON b.id = m.batch_id
		LEFT JOIN load_units lu ON lu.id = m.load_unit_id
		LEFT JOIN warehouse_problems p ON p.id = m.problem_id
		WHERE m.gtin IN ($1, lpad($1, 14, '0')) AND m.status = $2
		ORDER BY m.cis
		FOR UPDATE OF m`, barcode, model.CZMarkInStock)
	if err != nil {
		return nil, fmt.Errorf("марки под перепривязку: %w", err)
	}
	defer rows.Close()
	var groups []regradeGroup
	index := map[regradePlace]int{}
	cells := map[string]bool{}
	for rows.Next() {
		var cis string
		var cell, iwh *string
		var g regradePlace
		var inProblem bool
		if err := rows.Scan(&cis, &g.loadUnit, &cell, &iwh, &g.good, &g.batch, &g.date, &inProblem); err != nil {
			return nil, fmt.Errorf("разобрать марку под перепривязку: %w", err)
		}
		if inProblem {
			return nil, model.ErrRegradeOpenProblem
		}
		if cell == nil || iwh == nil {
			return nil, model.ErrRegradeBoxNotPlaced
		}
		g.cell, g.iwh = *cell, *iwh
		cells[g.cell] = true
		i, ok := index[g]
		if !ok {
			i = len(groups)
			index[g] = i
			groups = append(groups, regradeGroup{regradePlace: g})
		}
		groups[i].marks = append(groups[i].marks, cis)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("марки под перепривязку: %w", err)
	}
	return groups, guardRegradeCells(ctx, q, cells)
}

// guardRegradeCells - отказ, если ячейка марок сейчас пересчитывается: смена товара посреди
// подсчёта сбила бы факт ячейки (решение 2026-10-28 - отказ, не предупреждение).
func guardRegradeCells(ctx context.Context, q Querier, cells map[string]bool) error {
	if len(cells) == 0 {
		return nil
	}
	ids := make([]string, 0, len(cells))
	for id := range cells {
		ids = append(ids, id)
	}
	var address string
	var number int64
	err := q.QueryRow(ctx, `
		SELECT c.address, st.number
		FROM stocktake_cells sc
		JOIN stocktakes st ON st.id = sc.stocktake_id
		JOIN cells c ON c.id = sc.cell_id
		WHERE sc.cell_id = ANY($1::uuid[]) AND sc.status = 'counting' AND st.status <> 'closed'
		ORDER BY c.address
		LIMIT 1`, ids).Scan(&address, &number)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("пересчёт в ячейках марок: %w", err)
	}
	return fmt.Errorf("%w: ячейка %s, пересчёт № %d", model.ErrRegradeCellCounting, address, number)
}

// regradeMarks переводит сведённые марки на новый товар, записывает проблему «Пересорт» с её
// строками и журнал. Возвращает число переведённых марок.
func regradeMarks(ctx context.Context, q Querier, in model.RegradeInput, from, problemID string, groups []regradeGroup) (int, error) {
	var warehouse, gtin string
	if err := q.QueryRow(ctx, `
		SELECT c.warehouse_id::text, m.gtin FROM cells c, cz_marks m
		WHERE c.id = $1::uuid AND m.cis = $2`, groups[0].cell, groups[0].marks[0]).Scan(&warehouse, &gtin); err != nil {
		return 0, fmt.Errorf("склад пересорта: %w", err)
	}
	total := 0
	for _, g := range groups {
		total += len(g.marks)
	}
	if _, err := q.Exec(ctx, `
		INSERT INTO warehouse_problems
			(id, warehouse_id, good_id, qty, from_good_id, barcode, reason, comment, created_by)
		VALUES ($1::uuid, $2::uuid, $3::uuid, $4, $5::uuid, $6, $7, $8, $9::uuid)`,
		problemID, warehouse, in.GoodID, total, from, in.Barcode, model.ProblemReasonRegrade,
		"Перепривязка GTIN "+gtin, in.UserID); err != nil {
		return 0, fmt.Errorf("записать пересорт: %w", err)
	}

	for i, g := range groups {
		qty := decimal.NewFromInt(int64(len(g.marks)))
		batch, err := getOrCreateBatch(ctx, q, in.GoodID, g.date)
		if err != nil {
			return 0, err
		}
		if err := regradeGroupStock(ctx, q, g, in.GoodID, batch, qty); err != nil {
			return 0, err
		}
		if _, err := q.Exec(ctx, `
			UPDATE cz_marks SET good_id = $2::uuid, batch_id = $3::uuid, problem_id = $4::uuid,
			                    updated_at = now()
			WHERE cis = ANY($1::text[])`, g.marks, in.GoodID, batch, problemID); err != nil {
			return 0, fmt.Errorf("перевести марки на товар: %w", err)
		}
		if _, err := q.Exec(ctx, `
			INSERT INTO warehouse_problem_lines
				(problem_id, line_no, cell_id, load_unit_id, good_id, batch_id, qty)
			VALUES ($1::uuid, $2, $3::uuid, NULLIF($4, '')::uuid, $5::uuid, $6::uuid, $7::numeric)`,
			problemID, i+1, g.cell, g.loadUnit, in.GoodID, batch, qty.String()); err != nil {
			return 0, fmt.Errorf("записать строку пересорта: %w", err)
		}
	}

	details, err := json.Marshal(map[string]any{
		"barcode": in.Barcode, "gtin": gtin, "from_good_id": from, "to_good_id": in.GoodID,
		"marks": total,
	})
	if err != nil {
		return 0, fmt.Errorf("пересорт для журнала: %w", err)
	}
	if _, err := q.Exec(ctx, `
		INSERT INTO audit_log (user_id, action, entity_type, entity_id, details)
		VALUES ($1::uuid, 'barcode.regrade', 'warehouse_problem', $2, $3::jsonb)`,
		in.UserID, problemID, string(details)); err != nil {
		return 0, fmt.Errorf("журнал пересорта: %w", err)
	}
	return total, nil
}

// regradeGroupStock перекладывает остаток группы марок с прежнего товара на новый: строку
// остатка ячейки и, если марки в коробе, строку его состава.
func regradeGroupStock(ctx context.Context, q Querier, g regradeGroup, good, batch string, qty decimal.Decimal) error {
	if g.loadUnit != "" {
		if err := takeFromLoadUnit(ctx, q, g.loadUnit, g.good, g.batch, qty); err != nil {
			return fmt.Errorf("пересорт: состав короба: %w", err)
		}
		if _, err := q.Exec(ctx, `
			INSERT INTO lu_content (load_unit_id, good_id, batch_id, qty)
			VALUES ($1::uuid, $2::uuid, $3::uuid, $4::numeric)
			ON CONFLICT (load_unit_id, good_id, batch_id) DO UPDATE SET qty = lu_content.qty + EXCLUDED.qty`,
			g.loadUnit, good, batch, qty.String()); err != nil {
			return fmt.Errorf("пересорт: положить товар в короб: %w", err)
		}
	}
	if err := removeStock(ctx, q, model.StockKey{
		CellID: g.cell, GoodID: g.good, BatchID: g.batch, InternalWarehouseID: g.iwh,
	}, qty); err != nil {
		return fmt.Errorf("пересорт: остаток прежнего товара: %w", err)
	}
	return addStock(ctx, q, model.StockKey{
		CellID: g.cell, GoodID: good, BatchID: batch, InternalWarehouseID: g.iwh,
	}, qty)
}

// IsRegradeRefusal - отказ перепривязки по существу: его текст - для кладовщика.
func IsRegradeRefusal(err error) bool {
	for _, e := range []error{model.ErrRegradeNotBound, model.ErrRegradeSameGood, model.ErrRegradeOpenProblem,
		model.ErrRegradeCellCounting, model.ErrRegradeBoxNotPlaced, model.ErrGoodNotFound} {
		if errors.Is(err, e) {
			return true
		}
	}
	return false
}
