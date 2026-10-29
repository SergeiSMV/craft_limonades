package repository

import (
	"context"
	"fmt"
	"sort"

	"craftwms/internal/model"
	"craftwms/internal/movement"
)

// Снимок документа «Движение» (P5-04).
//
// Одна форма на размещение, перемещение и пополнение (P6-07): операция видна в шапке, а строки
// у всех одни — товар · партия · откуда · куда · количество. Снимок собирается в транзакции
// проведения, после записи строк: короба к этому моменту уже переехали, но их состав
// размещение не меняет, поэтому разворот видит ровно то, что переехало (P3-01).

// savePutawayDocument сохраняет «Движение» по сеансу размещения и открывает его журнал.
//
// Повтор безвреден, как у остальных форм: документ по сеансу один (уникальность источника),
// второе событие «сформирован» не пишется. На практике повтор упирается в первичный ключ
// putaways раньше.
func savePutawayDocument(ctx context.Context, q Querier, putawayID string) error {
	snap, author, err := buildPutawaySnapshot(ctx, q, putawayID)
	if err != nil {
		return err
	}
	documentID, err := saveDocument(ctx, q, model.ReportDocument{
		Kind:       model.ReportKindMovement,
		SourceType: model.SourceTypePutaway,
		SourceID:   putawayID,
		Snapshot:   snap,
	})
	if err != nil {
		return err
	}
	if documentID == "" {
		return nil
	}
	// Автор события — кто размещал: документ рождается операцией, своего создателя у него нет.
	return logEvent(ctx, q, documentID, model.DocEventCreated, author, "")
}

// buildPutawaySnapshot собирает шапку и товарные строки «Движения» размещения. Возвращает
// и автора сеанса — он нужен журналу документа.
//
// Основание — задание и то, из чего оно родилось: приёмка (поставщик и его накладная) или
// решение «разместить» по проблеме склада (ADHOC-55) — тогда её номер. Строки —
// разворот строк сеанса: короб раскладывается по составу, россыпь проходит как есть,
// одинаковые товар · партия · откуда · куда складываются (пакет movement, P4-09-1).
func buildPutawaySnapshot(ctx context.Context, q Querier, putawayID string) (model.ReportSnapshot, string, error) {
	snap := model.ReportSnapshot{Operation: model.MovementOperationPutaway}
	var author string
	var supplier, docNumber, docDate *string
	var problemNumber *int64
	if err := q.QueryRow(ctx, `
		SELECT w.code, w.name, u.full_name, p.created_by::text, p.posted_at, t.number,
		       s.name, r.doc_number, to_char(r.doc_date, 'YYYY-MM-DD'), wp.number
		FROM putaways p
		JOIN warehouses w      ON w.id = p.warehouse_id
		JOIN users u           ON u.id = p.created_by
		JOIN warehouse_tasks t ON t.id = p.task_id
		LEFT JOIN receipts r   ON r.id = t.receipt_id
		LEFT JOIN suppliers s  ON s.id = r.supplier_id
		LEFT JOIN warehouse_problems wp ON wp.id = t.problem_id
		WHERE p.id = $1::uuid`, putawayID).
		Scan(&snap.WarehouseCode, &snap.WarehouseName, &snap.Executor, &author, &snap.CreatedAt,
			&snap.TaskNumber, &supplier, &docNumber, &docDate, &problemNumber); err != nil {
		return model.ReportSnapshot{}, "", fmt.Errorf("снимок движения, шапка: %w", err)
	}
	snap.Supplier, snap.DocNumber, snap.DocDate = deref(supplier), deref(docNumber), deref(docDate)
	if problemNumber != nil {
		snap.ProblemNumber = *problemNumber
	}

	moves, err := putawayMoves(ctx, q, putawayID)
	if err != nil {
		return model.ReportSnapshot{}, "", err
	}
	expanded, err := movement.Expand(ctx, moves, NewLoadUnitContents(q))
	if err != nil {
		return model.ReportSnapshot{}, "", fmt.Errorf("снимок движения, разворот: %w", err)
	}
	snap.Rows, err = movementSnapshotRows(ctx, q, expanded)
	if err != nil {
		return model.ReportSnapshot{}, "", err
	}
	sortMovementRows(snap.Rows)
	return snap, author, nil
}

// sortMovementRows упорядочивает строки «Движения»: откуда, куда, наименование, дата выпуска.
// Оператор заносит в 1С перемещение парой ячеек, и строки одной пары должны идти подряд.
func sortMovementRows(rows []model.ReportSnapshotRow) {
	sort.SliceStable(rows, func(i, j int) bool {
		a, b := rows[i], rows[j]
		if a.FromCellAddress != b.FromCellAddress {
			return a.FromCellAddress < b.FromCellAddress
		}
		if a.CellAddress != b.CellAddress {
			return a.CellAddress < b.CellAddress
		}
		if a.GoodName != b.GoodName {
			return a.GoodName < b.GoodName
		}
		return a.ProductionDate < b.ProductionDate
	})
}

// saveMovementDocument публикует «Движение» по документу перемещения или пополнения (P6-07)
// и открывает его журнал. Зовётся в транзакции проведения, после записи строк.
//
// Что: moves — товарные движения документа по шагам: короб уже разложен по составу на
// момент своего переноса, товар — как есть.
// Зачем «нулевые» отбрасываются: товар из короба в россыпь той же ячейки (и обратно) остаток
//
//	ячейки не меняет, а 1С коробов не знает — для неё ничего не переехало. Документ, где
//	все строки такие, не публикуется вовсе: оператору нечего заносить.
//
// Повтор безвреден: документ по движению один (уникальность источника), а повтор операции
// упирается в первичный ключ movements раньше.
func saveMovementDocument(ctx context.Context, q Querier, movementID string, moves []movement.Move) error {
	snap, author, err := buildMovementSnapshot(ctx, q, movementID, moves)
	if err != nil {
		return err
	}
	if len(snap.Rows) == 0 {
		return nil
	}
	documentID, err := saveDocument(ctx, q, model.ReportDocument{
		Kind:       model.ReportKindMovement,
		SourceType: model.SourceTypeMovement,
		SourceID:   movementID,
		Snapshot:   snap,
	})
	if err != nil {
		return err
	}
	if documentID == "" {
		return nil
	}
	return logEvent(ctx, q, documentID, model.DocEventCreated, author, "")
}

// buildMovementSnapshot собирает шапку и строки «Движения» перемещения или пополнения.
// Операция — вид документа движения; основания (задания, поставщика) у перемещения нет.
func buildMovementSnapshot(ctx context.Context, q Querier, movementID string, moves []movement.Move) (model.ReportSnapshot, string, error) {
	var snap model.ReportSnapshot
	var author string
	if err := q.QueryRow(ctx, `
		SELECT w.code, w.name, u.full_name, m.created_by::text, m.posted_at, m.kind
		FROM movements m
		JOIN warehouses w ON w.id = m.warehouse_id
		JOIN users u      ON u.id = m.created_by
		WHERE m.id = $1::uuid`, movementID).
		Scan(&snap.WarehouseCode, &snap.WarehouseName, &snap.Executor, &author, &snap.CreatedAt,
			&snap.Operation); err != nil {
		return model.ReportSnapshot{}, "", fmt.Errorf("снимок движения, шапка: %w", err)
	}

	// Короба в moves уже разложены по составу, поэтому состав разворот не читает: агрегирует
	// одинаковые товар · партия · откуда · куда и отбрасывает нулевые итоги.
	expanded, err := movement.Expand(ctx, moves, NewLoadUnitContents(q))
	if err != nil {
		return model.ReportSnapshot{}, "", fmt.Errorf("снимок движения, разворот: %w", err)
	}
	lines := make([]movement.Line, 0, len(expanded))
	for _, l := range expanded {
		if l.FromCellID != l.ToCellID {
			lines = append(lines, l)
		}
	}
	snap.Rows, err = movementSnapshotRows(ctx, q, lines)
	if err != nil {
		return model.ReportSnapshot{}, "", err
	}
	sortMovementRows(snap.Rows)
	return snap, author, nil
}

// putawayMoves читает строки сеанса как движения разворота, в порядке ТСД.
func putawayMoves(ctx context.Context, q Querier, putawayID string) ([]movement.Move, error) {
	rows, err := q.Query(ctx, `
		SELECT load_unit_id::text, good_id::text, batch_id::text, qty::text,
		       from_cell_id::text, to_cell_id::text
		FROM putaway_lines WHERE putaway_id = $1::uuid ORDER BY line_no`, putawayID)
	if err != nil {
		return nil, fmt.Errorf("снимок движения, строки: %w", err)
	}
	defer rows.Close()
	moves := make([]movement.Move, 0)
	for rows.Next() {
		var lu, good, batch, qty *string
		var m movement.Move
		if err := rows.Scan(&lu, &good, &batch, &qty, &m.FromCellID, &m.ToCellID); err != nil {
			return nil, fmt.Errorf("снимок движения, разбор строки: %w", err)
		}
		m.LoadUnitID, m.GoodID, m.BatchID = deref(lu), deref(good), deref(batch)
		if qty != nil {
			if m.Qty, err = parseQty(*qty); err != nil {
				return nil, err
			}
		}
		moves = append(moves, m)
	}
	return moves, rows.Err()
}

// snapshotLineRef — грань строки разворота в идентификаторах: по ней справочные поля
// возвращаются к своей строке.
type snapshotLineRef struct {
	goodID, batchID, fromCellID, toCellID string
}

// movementSnapshotRows обогащает товарные строки разворота для человека: адреса ячеек, код
// и наименование товара, дата партии. Порядок строк — порядок разворота; сортирует форма.
//
// Общая для всех форм с движением: у прихода нет ячейки-отправителя, у отгрузки (P9) не
// будет адресата — пустая ячейка даёт пустой адрес.
func movementSnapshotRows(ctx context.Context, q Querier, lines []movement.Line) ([]model.ReportSnapshotRow, error) {
	out := make([]model.ReportSnapshotRow, 0, len(lines))
	if len(lines) == 0 {
		return out, nil
	}
	// Справочные поля — одним запросом на все строки, а не по запросу на строку.
	goods, batches, froms, tos := []string{}, []string{}, []string{}, []string{}
	for _, l := range lines {
		goods = append(goods, l.GoodID)
		batches = append(batches, l.BatchID)
		froms = append(froms, l.FromCellID)
		tos = append(tos, l.ToCellID)
	}
	rows, err := q.Query(ctx, `
		SELECT x.good_id, x.batch_id, x.from_id, x.to_id,
		       COALESCE(cf.address, ''), COALESCE(ct.address, ''),
		       g.code, g.name, b.production_date::text
		FROM unnest($1::text[], $2::text[], $3::text[], $4::text[]) AS x(good_id, batch_id, from_id, to_id)
		JOIN goods g        ON g.id = x.good_id::uuid
		JOIN batches b      ON b.id = x.batch_id::uuid
		LEFT JOIN cells cf  ON cf.id = NULLIF(x.from_id, '')::uuid
		LEFT JOIN cells ct  ON ct.id = NULLIF(x.to_id, '')::uuid`, goods, batches, froms, tos)
	if err != nil {
		return nil, fmt.Errorf("снимок документа, справочники: %w", err)
	}
	defer rows.Close()
	refs := make(map[snapshotLineRef]model.ReportSnapshotRow, len(lines))
	for rows.Next() {
		var ref snapshotLineRef
		var row model.ReportSnapshotRow
		if err := rows.Scan(&ref.goodID, &ref.batchID, &ref.fromCellID, &ref.toCellID,
			&row.FromCellAddress, &row.CellAddress, &row.GoodCode, &row.GoodName, &row.ProductionDate); err != nil {
			return nil, fmt.Errorf("снимок документа, разбор строки: %w", err)
		}
		refs[ref] = row
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	for _, l := range lines {
		row, ok := refs[snapshotLineRef{goodID: l.GoodID, batchID: l.BatchID, fromCellID: l.FromCellID, toCellID: l.ToCellID}]
		if !ok {
			// Строка уже проведена по этим же ссылкам в этой транзакции — пропасть они не могут.
			return nil, fmt.Errorf("снимок документа: нет справочных данных для строки %+v", l)
		}
		row.Qty = l.Qty.String()
		out = append(out, row)
	}
	return out, nil
}
