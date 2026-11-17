package repository

import (
	"context"
	"errors"
	"fmt"
	"sort"

	"github.com/shopspring/decimal"

	"craftwms/internal/model"
)

// Отказы строк ввода остатков с коробами и марками (ADHOC-46).
var (
	// ErrLoadUnitExists - короб с этим QR уже заведён на складе: проход его не пересчитывает.
	ErrLoadUnitExists = errors.New("load unit already exists")
	// ErrEntryDuplicate - короб, упаковка или марка уже введены в другой ячейке этого прохода.
	ErrEntryDuplicate = errors.New("already entered in another cell of the session")
	// ErrEntryCellHasMarks - в ячейке лежат марки россыпью того же товара и партии: SET россыпи
	// разошёлся бы с числом марок.
	ErrEntryCellHasMarks = errors.New("cell already has loose marks of this good and batch")
	// ErrEntryEmptyBox - короб прохода без товара.
	ErrEntryEmptyBox = errors.New("stock entry box has no goods")
)

//* --- Содержимое ячейки в сессии --- *//

// clearSessionCell удаляет содержимое ячейки в сессии: короба (с ними - строки в коробах и их
// марки), строки россыпи (с ними - марки), упаковки ЧЗ.
func clearSessionCell(ctx context.Context, q Querier, sessionID, cellID string) error {
	for _, sql := range []string{
		`DELETE FROM stock_entry_load_units WHERE session_id = $1::uuid AND cell_id = $2::uuid`,
		`DELETE FROM stock_entry_lines WHERE session_id = $1::uuid AND cell_id = $2::uuid`,
		`DELETE FROM stock_entry_cz_groups WHERE session_id = $1::uuid AND cell_id = $2::uuid`,
	} {
		if _, err := q.Exec(ctx, sql, sessionID, cellID); err != nil {
			return fmt.Errorf("очистить ячейку в сессии: %w", err)
		}
	}
	return nil
}

// insertSessionCZ записывает короба и упаковки ЧЗ ячейки в сессию - до строк: строка ссылается
// на свой короб внешним ключом.
func insertSessionCZ(ctx context.Context, q Querier, sessionID string, in StockEntryCellInput) error {
	for _, lu := range in.LoadUnits {
		if _, err := q.Exec(ctx, `
			INSERT INTO stock_entry_load_units (session_id, load_unit_id, cell_id, kind, cz_code)
			VALUES ($1::uuid, $2::uuid, $3::uuid, $4, NULLIF($5, ''))`,
			sessionID, lu.ID, in.CellID, lu.Kind, lu.CZCode); err != nil {
			return fmt.Errorf("короб в сессии: %w", err)
		}
	}
	for _, g := range in.CZGroups {
		if _, err := q.Exec(ctx, `
			INSERT INTO stock_entry_cz_groups (session_id, cell_id, code, parent_code)
			VALUES ($1::uuid, $2::uuid, $3, NULLIF($4, ''))`,
			sessionID, in.CellID, g.Code, g.ParentCode); err != nil {
			return fmt.Errorf("упаковка ЧЗ в сессии: %w", err)
		}
	}
	return nil
}

// insertSessionMarks записывает марки строки сессии.
func insertSessionMarks(ctx context.Context, q Querier, sessionID, lineID string, marks []model.ReceiptMark) error {
	for _, m := range marks {
		if _, err := q.Exec(ctx, `
			INSERT INTO stock_entry_marks (session_id, line_id, cis, aggregate_code, discrepancy)
			VALUES ($1::uuid, $2::uuid, $3, NULLIF($4, ''), NULLIF($5, ''))`,
			sessionID, lineID, m.CIS, m.AggregateCode, m.Discrepancy); err != nil {
			return fmt.Errorf("марка %s в сессии: %w", m.CIS, err)
		}
	}
	return nil
}

// loadSessionCells читает содержимое сессии по ячейкам - в виде тех же входов, что присылает
// checkpoint: финал проверяет и проводит их тем же кодом. Ячейки - в порядке id: номера
// проблем и порядок журнала не должны зависеть от обхода словаря.
func loadSessionCells(ctx context.Context, q Querier, sessionID string) ([]StockEntryCellInput, error) {
	byCell := map[string]*StockEntryCellInput{}
	cell := func(id string) *StockEntryCellInput {
		c := byCell[id]
		if c == nil {
			c = &StockEntryCellInput{CellID: id}
			byCell[id] = c
		}
		return c
	}

	rows, err := q.Query(ctx, `
		SELECT cell_id::text, load_unit_id::text, kind, COALESCE(cz_code, '')
		FROM stock_entry_load_units WHERE session_id = $1::uuid
		ORDER BY cell_id, load_unit_id`, sessionID)
	if err != nil {
		return nil, fmt.Errorf("короба сессии: %w", err)
	}
	for rows.Next() {
		var cellID string
		var lu LoadUnitInput
		if err := rows.Scan(&cellID, &lu.ID, &lu.Kind, &lu.CZCode); err != nil {
			rows.Close()
			return nil, fmt.Errorf("разобрать короб сессии: %w", err)
		}
		c := cell(cellID)
		c.LoadUnits = append(c.LoadUnits, lu)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	rows, err = q.Query(ctx, `
		SELECT cell_id::text, code, COALESCE(parent_code, '')
		FROM stock_entry_cz_groups WHERE session_id = $1::uuid
		ORDER BY cell_id, code`, sessionID)
	if err != nil {
		return nil, fmt.Errorf("упаковки сессии: %w", err)
	}
	for rows.Next() {
		var cellID string
		g := model.CZAggregate{Kind: model.CZAggregateGroup}
		if err := rows.Scan(&cellID, &g.Code, &g.ParentCode); err != nil {
			rows.Close()
			return nil, fmt.Errorf("разобрать упаковку сессии: %w", err)
		}
		c := cell(cellID)
		c.CZGroups = append(c.CZGroups, g)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	marks, err := sessionMarks(ctx, q, sessionID)
	if err != nil {
		return nil, err
	}
	rows, err = q.Query(ctx, `
		SELECT id::text, cell_id::text, good_id::text, production_date::text, qty::text,
		       COALESCE(load_unit_id::text, '')
		FROM stock_entry_lines WHERE session_id = $1::uuid
		ORDER BY cell_id, load_unit_id NULLS FIRST, good_id, production_date`, sessionID)
	if err != nil {
		return nil, fmt.Errorf("строки сессии: %w", err)
	}
	for rows.Next() {
		var lineID, cellID, qty string
		var ln StockEntryLineInput
		if err := rows.Scan(&lineID, &cellID, &ln.GoodID, &ln.ProductionDate, &qty, &ln.LoadUnitID); err != nil {
			rows.Close()
			return nil, fmt.Errorf("разобрать строку сессии: %w", err)
		}
		if ln.Qty, err = decimal.NewFromString(qty); err != nil {
			rows.Close()
			return nil, fmt.Errorf("количество строки сессии %q: %w", qty, err)
		}
		ln.Marks = marks[lineID]
		c := cell(cellID)
		c.Lines = append(c.Lines, ln)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	ids := make([]string, 0, len(byCell))
	for id := range byCell {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	out := make([]StockEntryCellInput, 0, len(ids))
	for _, id := range ids {
		out = append(out, *byCell[id])
	}
	return out, nil
}

// sessionMarks - марки сессии по строкам.
func sessionMarks(ctx context.Context, q Querier, sessionID string) (map[string][]model.ReceiptMark, error) {
	rows, err := q.Query(ctx, `
		SELECT line_id::text, cis, COALESCE(aggregate_code, ''), COALESCE(discrepancy, '')
		FROM stock_entry_marks WHERE session_id = $1::uuid
		ORDER BY cis`, sessionID)
	if err != nil {
		return nil, fmt.Errorf("марки сессии: %w", err)
	}
	defer rows.Close()
	out := map[string][]model.ReceiptMark{}
	for rows.Next() {
		var lineID string
		var m model.ReceiptMark
		if err := rows.Scan(&lineID, &m.CIS, &m.AggregateCode, &m.Discrepancy); err != nil {
			return nil, fmt.Errorf("разобрать марку сессии: %w", err)
		}
		out[lineID] = append(out[lineID], m)
	}
	return out, rows.Err()
}

//* --- Отказы строк --- *//

// guardEntryCell - отказы строк одной ячейки (checkpoint).
func guardEntryCell(ctx context.Context, q Querier, sessionID string, in StockEntryCellInput, inSession bool) error {
	bad, total, err := entryCellRejections(ctx, q, sessionID, in, inSession)
	if err != nil {
		return err
	}
	if len(bad) > 0 {
		return &DocumentLinesError{Total: total, Lines: bad}
	}
	return nil
}

// guardSessionCells - отказы строк всех ячеек сессии (финал), одним списком.
func guardSessionCells(ctx context.Context, q Querier, sessionID string, cells []StockEntryCellInput) error {
	var bad []LineRejection
	total := 0
	for _, c := range cells {
		b, n, err := entryCellRejections(ctx, q, sessionID, c, false)
		if err != nil {
			return err
		}
		for _, r := range b {
			r.Line += total
			bad = append(bad, r)
		}
		total += n
	}
	if len(bad) > 0 {
		return &DocumentLinesError{Total: total, Lines: bad}
	}
	return nil
}

// entryCellRejections проверяет ячейку прохода и возвращает её плохие строки и число строк.
//
// Строки ячейки для кладовщика - её короба, упаковки и строки товара; каждая проверяется
// целиком, чтобы назвать все плохие сразу (ADHOC-40).
// [inSession] - проверять и повторы с другими ячейками прохода: на checkpoint ячейка ещё не
// в сессии, на финале она уже там, и сравнивать её с ней самой нельзя.
func entryCellRejections(ctx context.Context, q Querier, sessionID string, in StockEntryCellInput, inSession bool) ([]LineRejection, int, error) {
	var bad []LineRejection
	n := 0
	reject := func(label string, err error) {
		bad = append(bad, LineRejection{Line: n, Label: label, Err: err})
	}
	cellAddr := cellText(ctx, q, in.CellID)

	boxGoods := map[string]bool{}
	for _, ln := range in.Lines {
		if ln.LoadUnitID != "" && ln.Qty.IsPositive() {
			boxGoods[ln.LoadUnitID] = true
		}
	}
	for _, lu := range in.LoadUnits {
		n++
		label := cellAddr + " · " + entryBoxText(lu)
		err := guardEntryBox(ctx, q, sessionID, lu, inSession)
		if err == nil && !boxGoods[lu.ID] {
			err = ErrEntryEmptyBox
		}
		if err != nil {
			if !isEntryRejection(err) {
				return nil, 0, err
			}
			reject(label, err)
		}
	}
	for _, g := range in.CZGroups {
		n++
		if err := guardEntryGroup(ctx, q, sessionID, g.Code, inSession); err != nil {
			if !isEntryRejection(err) {
				return nil, 0, err
			}
			reject(cellAddr+" · упаковка ЧЗ "+g.Code, err)
		}
	}

	marked, err := entryMarkedGoods(ctx, q, in.Lines)
	if err != nil {
		return nil, 0, err
	}
	iwh, err := defaultInternalWarehouse(ctx, q)
	if err != nil {
		return nil, 0, err
	}
	boxes := map[string]LoadUnitInput{}
	for _, lu := range in.LoadUnits {
		boxes[lu.ID] = lu
	}
	for _, ln := range in.Lines {
		n++
		label := cellAddr + " · " + goodText(ctx, q, ln.GoodID, ln.ProductionDate, ln.Qty)
		if lu, ok := boxes[ln.LoadUnitID]; ok {
			label += " · " + entryBoxText(lu)
		}
		if err := guardEntryLine(ctx, q, sessionID, in.CellID, iwh, ln, marked[ln.GoodID], inSession); err != nil {
			if !isEntryRejection(err) {
				return nil, 0, err
			}
			reject(label, err)
		}
	}
	return bad, n, nil
}

// guardEntryBox - короб прохода ещё не заведён ни на складе, ни в другой ячейке прохода.
func guardEntryBox(ctx context.Context, q Querier, sessionID string, lu LoadUnitInput, inSession bool) error {
	var exists bool
	if err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM load_units WHERE id = $1::uuid)`,
		lu.ID).Scan(&exists); err != nil {
		return fmt.Errorf("проверить короб: %w", err)
	}
	if exists {
		return ErrLoadUnitExists
	}
	if lu.CZCode != "" {
		if err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM cz_aggregates WHERE code = $1)`,
			lu.CZCode).Scan(&exists); err != nil {
			return fmt.Errorf("проверить короб ЧЗ: %w", err)
		}
		if exists {
			return model.ErrCZAggregateExists
		}
	}
	if !inSession {
		return nil
	}
	if err := q.QueryRow(ctx, `
		SELECT EXISTS (SELECT 1 FROM stock_entry_load_units
		               WHERE session_id = $1::uuid AND (load_unit_id = $2::uuid OR cz_code = NULLIF($3, '')))`,
		sessionID, lu.ID, lu.CZCode).Scan(&exists); err != nil {
		return fmt.Errorf("проверить короб в сессии: %w", err)
	}
	if exists {
		return ErrEntryDuplicate
	}
	return nil
}

// guardEntryGroup - групповая упаковка ЧЗ ещё не заведена ни на складе, ни в другой ячейке.
func guardEntryGroup(ctx context.Context, q Querier, sessionID, code string, inSession bool) error {
	var exists bool
	if err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM cz_aggregates WHERE code = $1)`,
		code).Scan(&exists); err != nil {
		return fmt.Errorf("проверить упаковку ЧЗ: %w", err)
	}
	if exists {
		return model.ErrCZAggregateExists
	}
	if !inSession {
		return nil
	}
	if err := q.QueryRow(ctx, `
		SELECT EXISTS (SELECT 1 FROM stock_entry_cz_groups WHERE session_id = $1::uuid AND code = $2)`,
		sessionID, code).Scan(&exists); err != nil {
		return fmt.Errorf("проверить упаковку ЧЗ в сессии: %w", err)
	}
	if exists {
		return ErrEntryDuplicate
	}
	return nil
}

// guardEntryLine - строка товара ячейки.
//
// Маркируемый товар - только марками, ровно по марке на единицу; марка ещё не в учёте и не в
// другой ячейке прохода; в ячейке нет марок россыпью этого товара и партии на «Основном» - SET
// остатка грани их бы не учёл. Строка с нулём маркируемого товара допустима: она обнуляет грань,
// если марок россыпью в ячейке нет.
func guardEntryLine(ctx context.Context, q Querier, sessionID, cellID, iwh string, ln StockEntryLineInput, marked, inSession bool) error {
	if len(ln.Marks) > 0 && !ln.Qty.Equal(decimal.NewFromInt(int64(len(ln.Marks)))) {
		return model.ErrCZMarksQtyMismatch
	}
	if marked && len(ln.Marks) == 0 && ln.Qty.IsPositive() {
		return model.ErrCZMarksRequired
	}
	if len(ln.Marks) > 0 {
		cis := make([]string, len(ln.Marks))
		for i, m := range ln.Marks {
			cis[i] = m.CIS
		}
		var exists bool
		if err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM cz_marks WHERE cis = ANY($1))`,
			cis).Scan(&exists); err != nil {
			return fmt.Errorf("проверить марки: %w", err)
		}
		if exists {
			return model.ErrCZMarkExists
		}
		if inSession {
			if err := q.QueryRow(ctx, `
				SELECT EXISTS (SELECT 1 FROM stock_entry_marks WHERE session_id = $1::uuid AND cis = ANY($2))`,
				sessionID, cis).Scan(&exists); err != nil {
				return fmt.Errorf("проверить марки в сессии: %w", err)
			}
			if exists {
				return ErrEntryDuplicate
			}
		}
	}
	var hasMarks bool
	if err := q.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM cz_marks m JOIN batches b ON b.id = m.batch_id
			WHERE m.cell_id = $1::uuid AND m.internal_warehouse_id = $2::uuid
			  AND m.status = 'in_stock' AND m.good_id = $3::uuid AND b.production_date = $4::date)`,
		cellID, iwh, ln.GoodID, ln.ProductionDate).Scan(&hasMarks); err != nil {
		return fmt.Errorf("проверить марки в ячейке: %w", err)
	}
	if hasMarks {
		return ErrEntryCellHasMarks
	}
	return nil
}

// entryMarkedGoods - какие товары ячейки маркируемые: признак в справочнике или марки в любой
// строке этого товара в ячейке (марка сделает его маркируемым на финале, CZ-05).
func entryMarkedGoods(ctx context.Context, q Querier, lines []StockEntryLineInput) (map[string]bool, error) {
	marked := map[string]bool{}
	var goods []string
	for _, ln := range lines {
		if len(ln.Marks) > 0 {
			marked[ln.GoodID] = true
		}
		goods = append(goods, ln.GoodID)
	}
	if len(goods) == 0 {
		return marked, nil
	}
	rows, err := q.Query(ctx, `SELECT id::text FROM goods WHERE id = ANY($1::uuid[]) AND cz_marked`, goods)
	if err != nil {
		return nil, fmt.Errorf("маркируемые товары: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("разобрать маркируемый товар: %w", err)
		}
		marked[id] = true
	}
	return marked, rows.Err()
}

// entryRejections - ошибки, которыми отказывает строка ввода остатков. Ссылка в никуда
// (несуществующий товар) - тоже отказ строки, а не сбой.
var entryRejections = []error{
	ErrLoadUnitExists, ErrEntryDuplicate, ErrEntryCellHasMarks, ErrEntryEmptyBox,
	model.ErrCZAggregateExists, model.ErrCZMarkExists,
	model.ErrCZMarksRequired, model.ErrCZMarksQtyMismatch,
}

// isEntryRejection - отказ ли это строки ввода остатков.
func isEntryRejection(err error) bool {
	for _, target := range entryRejections {
		if errors.Is(err, target) {
			return true
		}
	}
	return false
}

// entryBoxText - короб прохода для человека: его ГЕ ещё нет, поэтому по входу, а не по базе.
func entryBoxText(lu LoadUnitInput) string {
	if lu.CZCode != "" {
		return czBoxText(lu.CZCode)
	}
	return labelBoxText(lu.ID)
}

//* --- Финал: остаток, короба, ЧЗ --- *//

// entryFacet - грань остатка, которой коснулся проход: ячейка · товар · партия на «Основном».
type entryFacet struct {
	cellID, goodID, productionDate string
}

// setSessionStock ставит остаток каждой грани прохода (SET) и возвращает партии граней и их
// число.
//
// Остаток грани = россыпь прохода + товар в коробах прохода + состав коробов «Основного»,
// которые уже лежали в ячейке до прохода (ADHOC-46): остаток ячейки включает товар в коробах,
// а уже размещённый короб проход не пересчитывает. Зовётся до размещения коробов прохода.
func setSessionStock(ctx context.Context, q Querier, cells []StockEntryCellInput, iwh string) (map[entryFacet]string, int, error) {
	var keys []entryFacet
	sums := map[entryFacet]decimal.Decimal{}
	for _, c := range cells {
		for _, ln := range c.Lines {
			k := entryFacet{cellID: c.CellID, goodID: ln.GoodID, productionDate: ln.ProductionDate}
			if _, ok := sums[k]; !ok {
				keys = append(keys, k)
			}
			sums[k] = sums[k].Add(ln.Qty)
		}
	}
	batches := map[entryFacet]string{}
	for _, k := range keys {
		batchID, err := getOrCreateBatch(ctx, q, k.goodID, k.productionDate)
		if err != nil {
			return nil, 0, err
		}
		batches[k] = batchID
		var placed string
		if err := q.QueryRow(ctx, `
			SELECT COALESCE(sum(c.qty), 0)::text
			FROM lu_content c JOIN load_units u ON u.id = c.load_unit_id
			WHERE u.cell_id = $1::uuid AND u.internal_warehouse_id = $2::uuid
			  AND c.good_id = $3::uuid AND c.batch_id = $4::uuid`,
			k.cellID, iwh, k.goodID, batchID).Scan(&placed); err != nil {
			return nil, 0, fmt.Errorf("состав коробов в ячейке: %w", err)
		}
		inBoxes, err := decimal.NewFromString(placed)
		if err != nil {
			return nil, 0, fmt.Errorf("состав коробов %q: %w", placed, err)
		}
		key := model.StockKey{CellID: k.cellID, GoodID: k.goodID, BatchID: batchID, InternalWarehouseID: iwh}
		if err := setStock(ctx, q, key, sums[k].Add(inBoxes)); err != nil {
			return nil, 0, err
		}
	}
	return batches, len(keys), nil
}

// placeSessionBoxes наполняет короба прохода и кладёт их в ячейки - через общую функцию
// размещения, она же пишет первую строку журнала с источником «ввод остатков».
func placeSessionBoxes(ctx context.Context, q Querier, sessionID string, cells []StockEntryCellInput, batches map[entryFacet]string) error {
	var author string
	if err := q.QueryRow(ctx, `SELECT created_by::text FROM stock_entry_sessions WHERE id = $1::uuid`,
		sessionID).Scan(&author); err != nil {
		return fmt.Errorf("автор сессии: %w", err)
	}
	for _, c := range cells {
		for _, ln := range c.Lines {
			if ln.LoadUnitID == "" || !ln.Qty.IsPositive() {
				continue
			}
			batchID := batches[entryFacet{cellID: c.CellID, goodID: ln.GoodID, productionDate: ln.ProductionDate}]
			if err := addLoadUnitContent(ctx, q, ln.LoadUnitID, ln.GoodID, batchID, ln.Qty.String()); err != nil {
				return err
			}
		}
		for _, lu := range c.LoadUnits {
			if err := placeLoadUnit(ctx, q, model.PlaceLoadUnitInput{
				LoadUnitID:   lu.ID,
				CellID:       c.CellID,
				Source:       model.PlacementStockEntry,
				UserID:       author,
				StockEntryID: &sessionID,
			}); err != nil {
				return err
			}
		}
	}
	return nil
}

// receiveSessionCZ записывает короба ЧЗ, упаковки и марки прохода и заводит проблемы по маркам
// с расхождением - общим приходом ЧЗ, как приёмка (CZ-05).
func receiveSessionCZ(ctx context.Context, q Querier, sessionID string, cells []StockEntryCellInput) error {
	in := CZIntakeInput{}
	if err := q.QueryRow(ctx, `
		SELECT warehouse_id::text, created_by::text FROM stock_entry_sessions WHERE id = $1::uuid`,
		sessionID).Scan(&in.WarehouseID, &in.CreatedBy); err != nil {
		return fmt.Errorf("шапка сессии: %w", err)
	}
	for _, c := range cells {
		in.LoadUnits = append(in.LoadUnits, c.LoadUnits...)
		in.CZGroups = append(in.CZGroups, c.CZGroups...)
		for _, ln := range c.Lines {
			in.Lines = append(in.Lines, model.ReceiptLineInput{
				GoodID: ln.GoodID, ProductionDate: ln.ProductionDate, CellID: c.CellID,
				LoadUnitID: ln.LoadUnitID, Qty: ln.Qty, Marks: ln.Marks,
			})
		}
	}
	return receiveCZ(ctx, q, in)
}
