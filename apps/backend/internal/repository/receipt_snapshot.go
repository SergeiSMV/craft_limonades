package repository

import (
	"context"
	"fmt"
	"sort"

	"craftwms/internal/model"
	"craftwms/internal/movement"
)

// Снимок документа «Поступление» (P4-10).
//
// Собирается в транзакции оприходования, после проводки строк: строки к этому моменту
// окончательны, а справочники читаются на момент завершения операции — дальше документ от них
// не зависит (P3-01). Оприходованная приёмка без документа невозможна, как и документ по
// неоприходованной.

// saveReceiptDocument сохраняет документ «Поступление» и открывает его журнал.
//
// Повтор безвреден: документ по приёмке один (уникальность источника), второе событие
// «сформирован» не пишется. На практике повтора и не бывает — оприходованный документ
// упирается в статус раньше, — но правило то же, что у ввода остатков.
func saveReceiptDocument(ctx context.Context, q Querier, receiptID string) error {
	snap, author, err := buildReceiptSnapshot(ctx, q, receiptID)
	if err != nil {
		return err
	}
	documentID, err := saveDocument(ctx, q, model.ReportDocument{
		Kind:       model.ReportKindReceipt,
		SourceType: model.SourceTypeReceipt,
		SourceID:   receiptID,
		Snapshot:   snap,
	})
	if err != nil {
		return err
	}
	if documentID == "" {
		return nil
	}
	// Автор события — тот, кто принимал: у документа нет собственного создателя, он рождается
	// операцией.
	return logEvent(ctx, q, documentID, model.DocEventCreated, author, "")
}

// receiptLineRef — строка приёмки в идентификаторах, как её подаёт разворот.
type receiptLineRef struct {
	goodID, batchID, cellID string
}

// buildReceiptSnapshot собирает шапку и товарные строки «Поступления». Возвращает и автора
// приёмки — он нужен журналу документа.
//
// Строки идут через разворот движений (P4-09-1): у приёмки они уже товарные (короб — лишь
// пометка строки), и разворот сводится к агрегации — строки разных коробов одного товара одной
// партии в одной ячейке складываются в одну. Короб в документе не показывается: 1С он не нужен.
// Разворот общий для всех отчётов, поэтому правила агрегации здесь те же, что будут у «Движения».
func buildReceiptSnapshot(ctx context.Context, q Querier, receiptID string) (model.ReportSnapshot, string, error) {
	var snap model.ReportSnapshot
	var author string
	var supplier *string
	if err := q.QueryRow(ctx, `
		SELECT w.code, w.name, s.name, u.full_name, r.created_by::text, COALESCE(r.posted_at, now())
		FROM receipts r
		JOIN warehouses w ON w.id = r.warehouse_id
		JOIN users u ON u.id = r.created_by
		LEFT JOIN suppliers s ON s.id = r.supplier_id
		WHERE r.id = $1::uuid`, receiptID).
		Scan(&snap.WarehouseCode, &snap.WarehouseName, &supplier, &snap.Executor, &author, &snap.CreatedAt); err != nil {
		return model.ReportSnapshot{}, "", fmt.Errorf("снимок поступления, шапка: %w", err)
	}
	if supplier != nil {
		snap.Supplier = *supplier
	}

	lines, err := listReceiptLines(ctx, q, receiptID)
	if err != nil {
		return model.ReportSnapshot{}, "", err
	}
	moves := make([]movement.Move, 0, len(lines))
	for _, ln := range lines {
		moves = append(moves, movement.Move{
			ToCellID: ln.CellID, GoodID: ln.GoodID, BatchID: ln.BatchID, Qty: ln.Qty,
		})
	}
	// Состав ГЕ не нужен — движения россыпью, — но источник передаётся честный: если однажды
	// приёмка начнёт принимать ГЕ целиком, разворот прочитает её состав в этой же транзакции.
	expanded, err := movement.Expand(ctx, moves, NewLoadUnitContents(q))
	if err != nil {
		return model.ReportSnapshot{}, "", fmt.Errorf("снимок поступления, разворот: %w", err)
	}

	snap.Rows, err = receiptSnapshotRows(ctx, q, expanded)
	if err != nil {
		return model.ReportSnapshot{}, "", err
	}
	return snap, author, nil
}

// receiptSnapshotRows обогащает товарные строки для человека: адрес ячейки, код и наименование
// товара, дата партии. Порядок — ячейка, наименование, дата выпуска: оператор сверяет документ
// по месту хранения, как и отчёт ввода остатков.
func receiptSnapshotRows(ctx context.Context, q Querier, lines []movement.Line) ([]model.ReportSnapshotRow, error) {
	out := make([]model.ReportSnapshotRow, 0, len(lines))
	if len(lines) == 0 {
		return out, nil
	}
	// Справочные поля — одним запросом на все строки, а не по запросу на строку.
	refs := make(map[receiptLineRef]model.ReportSnapshotRow, len(lines))
	goods, batches, cells := []string{}, []string{}, []string{}
	for _, l := range lines {
		goods = append(goods, l.GoodID)
		batches = append(batches, l.BatchID)
		cells = append(cells, l.ToCellID)
	}
	rows, err := q.Query(ctx, `
		SELECT x.good_id::text, x.batch_id::text, x.cell_id::text,
		       c.address, g.code, g.name, b.production_date::text
		FROM unnest($1::text[]::uuid[], $2::text[]::uuid[], $3::text[]::uuid[])
		     AS x(good_id, batch_id, cell_id)
		JOIN goods g   ON g.id = x.good_id
		JOIN batches b ON b.id = x.batch_id
		JOIN cells c   ON c.id = x.cell_id`, goods, batches, cells)
	if err != nil {
		return nil, fmt.Errorf("снимок поступления, справочники: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var ref receiptLineRef
		var row model.ReportSnapshotRow
		if err := rows.Scan(&ref.goodID, &ref.batchID, &ref.cellID,
			&row.CellAddress, &row.GoodCode, &row.GoodName, &row.ProductionDate); err != nil {
			return nil, fmt.Errorf("снимок поступления, разбор строки: %w", err)
		}
		refs[ref] = row
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	for _, l := range lines {
		row, ok := refs[receiptLineRef{goodID: l.GoodID, batchID: l.BatchID, cellID: l.ToCellID}]
		if !ok {
			// Строка уже проведена по этим же ссылкам в этой транзакции — пропасть они не могут.
			return nil, fmt.Errorf("снимок поступления: нет справочных данных для строки %+v", l)
		}
		row.Qty = l.Qty.String()
		out = append(out, row)
	}
	sort.SliceStable(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if a.CellAddress != b.CellAddress {
			return a.CellAddress < b.CellAddress
		}
		if a.GoodName != b.GoodName {
			return a.GoodName < b.GoodName
		}
		return a.ProductionDate < b.ProductionDate
	})
	return out, nil
}
