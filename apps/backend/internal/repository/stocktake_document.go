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

	for _, k := range order {
		a := byKey[k]
		if a.skipped {
			snap.Rows = append(snap.Rows, a.row)
			continue
		}
		if a.expected.IsZero() && a.fact.IsZero() {
			continue
		}
		a.row.Expected, a.row.Fact = a.expected.String(), a.fact.String()
		a.row.Diff = a.fact.Sub(a.expected).String()
		if a.notFound {
			a.row.Note = stocktakeNoteNotFound
		}
		snap.Rows = append(snap.Rows, a.row)
	}
	return snap, nil
}
