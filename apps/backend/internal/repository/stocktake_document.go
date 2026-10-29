package repository

import (
	"context"
	"fmt"

	"github.com/shopspring/decimal"

	"craftwms/internal/model"
)

// Документ «Инвентаризация» (P10-05) — один на пересчёт, в транзакции закрытия.
//
// Остаток WMS к факту приводит подсчёт каждой ячейки; документ нужен 1С: по нему оператор
// заносит расхождения и отмечает «Выполнено». Строки — все подсчитанные позиции по ячейке,
// товару, партии и складу WMS: россыпь и состав коробов складываются (1С знает товар, а не
// короба). Не найденное с проблемой склада помечено, неподсчитанная ячейка — строкой
// «не считалась».

// Пометки строк «Инвентаризации».
const (
	stocktakeNoteNotFound = "не найдено — проблема склада"
	stocktakeNoteSkipped  = "не считалась"
)

// saveStocktakeDocument сохраняет документ «Инвентаризация» и открывает его журнал от имени
// закрывшего.
func saveStocktakeDocument(ctx context.Context, q Querier, stocktakeID, userID string) error {
	snap, err := buildStocktakeSnapshot(ctx, q, stocktakeID)
	if err != nil {
		return err
	}
	documentID, err := saveDocument(ctx, q, model.ReportDocument{
		Kind:       model.ReportKindStocktake,
		SourceType: model.SourceTypeStocktake,
		SourceID:   stocktakeID,
		Snapshot:   snap,
	})
	if err != nil || documentID == "" {
		return err
	}
	return logEvent(ctx, q, documentID, model.DocEventCreated, userID, "")
}

// stocktakeRowKey — строка документа: ячейка · товар · партия · склад WMS.
type stocktakeRowKey struct{ cell, good, batch, iwh string }

// buildStocktakeSnapshot собирает шапку и строки «Инвентаризации».
func buildStocktakeSnapshot(ctx context.Context, q Querier, stocktakeID string) (model.ReportSnapshot, error) {
	var snap model.ReportSnapshot
	if err := q.QueryRow(ctx, `
		SELECT w.code, w.name, st.number, st.scope_kind, COALESCE(u.full_name, ''), COALESCE(st.closed_at, now())
		FROM stocktakes st
		JOIN warehouses w ON w.id = st.warehouse_id
		LEFT JOIN users u ON u.id = st.closed_by
		WHERE st.id = $1::uuid`, stocktakeID).
		Scan(&snap.WarehouseCode, &snap.WarehouseName, &snap.StocktakeNumber, &snap.ScopeKind,
			&snap.Executor, &snap.CreatedAt); err != nil {
		return snap, fmt.Errorf("снимок инвентаризации, шапка: %w", err)
	}

	// Товарные строки подсчитанных ячеек (россыпь и состав коробов) и по строке на каждую
	// неподсчитанную. Не найдено — проблема у строки короба или у марок строки россыпи.
	rows, err := q.Query(ctx, `
		SELECT c.address, sc.status = 'counted',
		       COALESCE(l.good_id::text, ''), g.code, COALESCE(g.name, ''),
		       COALESCE(to_char(b.production_date, 'YYYY-MM-DD'), ''),
		       COALESCE(l.batch_id::text, ''), COALESCE(l.internal_warehouse_id::text, ''),
		       COALESCE(iw.name, ''),
		       COALESCE(l.expected_qty, 0)::text, COALESCE(l.fact_qty, 0)::text,
		       COALESCE(bl.problem_id IS NOT NULL, false)
		           OR EXISTS (SELECT 1 FROM stocktake_marks m WHERE m.line_id = l.id AND m.problem_id IS NOT NULL)
		FROM stocktake_cells sc
		JOIN cells c ON c.id = sc.cell_id
		LEFT JOIN stocktake_lines l ON l.stocktake_cell_id = sc.id AND l.good_id IS NOT NULL
		                           AND sc.status = 'counted'
		LEFT JOIN stocktake_lines bl ON bl.stocktake_cell_id = sc.id AND bl.load_unit_id = l.load_unit_id
		                            AND bl.good_id IS NULL
		LEFT JOIN goods g ON g.id = l.good_id
		LEFT JOIN batches b ON b.id = l.batch_id
		LEFT JOIN internal_warehouses iw ON iw.id = l.internal_warehouse_id
		WHERE sc.stocktake_id = $1::uuid
		ORDER BY c.address, g.name, b.production_date, iw.name`, stocktakeID)
	if err != nil {
		return snap, fmt.Errorf("снимок инвентаризации, строки: %w", err)
	}
	defer rows.Close()

	// Строки копятся в порядке запроса (по адресу ячейки); неподсчитанная ячейка — тоже строка,
	// чтобы она стояла на своём месте среди подсчитанных.
	type agg struct {
		row            model.ReportSnapshotRow
		expected, fact decimal.Decimal
		notFound       bool
		skipped        bool
	}
	var order []stocktakeRowKey
	byKey := map[stocktakeRowKey]*agg{}
	for rows.Next() {
		var k stocktakeRowKey
		var counted, notFound bool
		var code *string
		var name, date, iwhName, expected, fact string
		if err := rows.Scan(&k.cell, &counted, &k.good, &code, &name, &date, &k.batch, &k.iwh, &iwhName,
			&expected, &fact, &notFound); err != nil {
			return snap, fmt.Errorf("разобрать строку инвентаризации: %w", err)
		}
		if !counted {
			byKey[k] = &agg{row: model.ReportSnapshotRow{CellAddress: k.cell, Note: stocktakeNoteSkipped}, skipped: true}
			order = append(order, k)
			continue
		}
		if k.good == "" {
			continue // подсчитанная ячейка без товара — пустая, строк нет
		}
		a, ok := byKey[k]
		if !ok {
			a = &agg{row: model.ReportSnapshotRow{
				CellAddress: k.cell, GoodCode: code, GoodName: name, ProductionDate: date,
				InternalWarehouse: iwhName,
			}}
			byKey[k] = a
			order = append(order, k)
		}
		e, err := decimal.NewFromString(expected)
		if err != nil {
			return snap, fmt.Errorf("ожидалось: %w", err)
		}
		f, err := decimal.NewFromString(fact)
		if err != nil {
			return snap, fmt.Errorf("факт: %w", err)
		}
		a.expected, a.fact = a.expected.Add(e), a.fact.Add(f)
		a.notFound = a.notFound || notFound
	}
	if err := rows.Err(); err != nil {
		return snap, fmt.Errorf("снимок инвентаризации, строки: %w", err)
	}

	marks, err := stocktakeMarks(ctx, q, stocktakeID)
	if err != nil {
		return snap, err
	}
	for _, k := range order {
		a := byKey[k]
		if a.skipped {
			snap.Rows = append(snap.Rows, a.row)
			continue
		}
		if a.expected.IsZero() && a.fact.IsZero() {
			continue
		}
		// Маркируемый товар — строка на марку (ADHOC-55); что марками не покрыто — общей строкой.
		expected, fact := a.expected, a.fact
		for _, m := range marks[k] {
			r := a.row
			r.Mark = m.cis
			e, f := markCount(m.expected), markCount(m.found)
			r.Expected, r.Fact, r.Diff = e.String(), f.String(), f.Sub(e).String()
			if a.notFound && m.expected && !m.found {
				r.Note = stocktakeNoteNotFound
			}
			snap.Rows = append(snap.Rows, r)
			expected, fact = expected.Sub(e), fact.Sub(f)
		}
		if len(marks[k]) > 0 && expected.IsZero() && fact.IsZero() {
			continue
		}
		a.row.Expected, a.row.Fact = expected.String(), fact.String()
		a.row.Diff = fact.Sub(expected).String()
		if a.notFound && len(marks[k]) == 0 {
			a.row.Note = stocktakeNoteNotFound
		}
		snap.Rows = append(snap.Rows, a.row)
	}
	return snap, nil
}

// stocktakeMark — марка строки «Инвентаризации»: ожидалась ли в ячейке и найдена ли.
type stocktakeMark struct {
	cis             string
	expected, found bool
}

// markCount — марка в количестве: 1 или 0.
func markCount(b bool) decimal.Decimal {
	if b {
		return decimal.NewFromInt(1)
	}
	return decimal.Zero
}

// stocktakeMarks — марки ЧЗ подсчитанных позиций по строке документа (ADHOC-55).
//
// Россыпь и вскрытый короб считаются марками (stocktake_marks): ожидалась — снимок при начале
// подсчёта, найдена — скан. Короб, подтверждённый целиком, марок в пересчёте не несёт — его
// марки берутся из состава короба: найдены, если позиция короба сошлась. Позиция короба, найденная частично, марки не делит — кто именно нашёлся, неизвестно,
// и она остаётся общей строкой.
func stocktakeMarks(ctx context.Context, q Querier, stocktakeID string) (map[stocktakeRowKey][]stocktakeMark, error) {
	rows, err := q.Query(ctx, `
		SELECT c.address, l.good_id::text, l.batch_id::text, l.internal_warehouse_id::text,
		       m.cis, m.expected, m.found
		FROM stocktake_marks m
		JOIN stocktake_lines l  ON l.id = m.line_id
		JOIN stocktake_cells sc ON sc.id = l.stocktake_cell_id AND sc.status = 'counted'
		JOIN cells c            ON c.id = sc.cell_id
		WHERE sc.stocktake_id = $1::uuid
		UNION ALL
		SELECT c.address, l.good_id::text, l.batch_id::text, l.internal_warehouse_id::text,
		       cm.cis, true, COALESCE(l.fact_qty, 0) >= l.expected_qty
		FROM stocktake_lines l
		JOIN stocktake_cells sc ON sc.id = l.stocktake_cell_id AND sc.status = 'counted'
		JOIN cells c            ON c.id = sc.cell_id
		JOIN cz_marks cm        ON cm.load_unit_id = l.load_unit_id
		                       AND cm.good_id = l.good_id AND cm.batch_id = l.batch_id
		WHERE sc.stocktake_id = $1::uuid AND l.good_id IS NOT NULL
		  AND (COALESCE(l.fact_qty, 0) = 0 OR l.fact_qty >= l.expected_qty)
		  AND NOT EXISTS (SELECT 1 FROM stocktake_marks sm WHERE sm.line_id = l.id)
		ORDER BY 5`, stocktakeID)
	if err != nil {
		return nil, fmt.Errorf("снимок инвентаризации, марки: %w", err)
	}
	defer rows.Close()
	out := map[stocktakeRowKey][]stocktakeMark{}
	for rows.Next() {
		var k stocktakeRowKey
		var m stocktakeMark
		if err := rows.Scan(&k.cell, &k.good, &k.batch, &k.iwh, &m.cis, &m.expected, &m.found); err != nil {
			return nil, fmt.Errorf("разобрать марку инвентаризации: %w", err)
		}
		out[k] = append(out[k], m)
	}
	return out, rows.Err()
}
