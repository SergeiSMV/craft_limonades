package repository

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
)

// KindStocktakeCellSubmit - подсчёт ячейки пересчёта (P10-03): факт россыпи и найденные короба
// одной операцией очереди.
const KindStocktakeCellSubmit = "stocktake_cell_submit"

// StocktakeCellSubmit проводит подсчёт ячейки пересчёта операцией очереди (P10-03).
func (r *OperationsRepository) StocktakeCellSubmit(ctx context.Context, operationID string, in model.StocktakeCellSubmitInput) (Applied, error) {
	return r.inTx(ctx, operationID, KindStocktakeCellSubmit, func(q Querier) (json.RawMessage, error) {
		res, err := stocktakeCellSubmit(ctx, q, in)
		if err != nil {
			return nil, missingReference(err)
		}
		return jsonResult(res)
	})
}

// stocktakeLine - строка снимка ячейки под подсчётом.
type stocktakeLine struct {
	id                         string
	loadUnit, good, batch, iwh string
	fact                       decimal.Decimal
	// foreign - короб найден не по снимку, перенесён сюда.
	foreign bool
}

// stocktakeCount - подсчёт одной ячейки пересчёта в транзакции операции.
type stocktakeCount struct {
	q        Querier
	c        lockedStocktakeCell
	id       string // ячейка пересчёта
	user     string
	notFound string // склад «Не найдено»
	loose    map[stocktakeLineKey]*stocktakeLine
	boxes    map[string]*stocktakeLine
	res      model.StocktakeCellResult
}

// stocktakeCellSubmit приводит остаток ячейки к факту подсчёта (P10-03).
//
// Что: строки снимка получают факт (не названная позиция - 0, недостача; названная сверх
// снимка - новая строка, излишек), остаток каждой позиции россыпи приводится к факту, правка
// пишется в audit_log. Не найденные короб и марки уходят на склад «Не найдено» проблемой склада
// с причиной «не найдено» - решение за офисом. Учётный короб или марка из другого места
// переносятся сюда - их нашли здесь.
// Зачем сразу по ячейке, а не при закрытии пересчёта: пока ячейка на подсчёте, движений через
// неё не было (иначе она сбита), и остаток равен снимку; к закрытию через неё пройдут движения,
// и факт утра разошёлся бы с остатком вечера (решение 2026-10-26).
// Как: ячейка сначала становится `counted` - свои правки остатка иначе сбили бы её собственный
// подсчёт (триггеры миграции 31). Правка россыпи - разницей факта с россыпью ПОСЛЕ проблем и
// переносов: так марки, ушедшие в «Не найдено», и перенесённые сюда не считаются дважды.
// Остаток меняется только примитивами addStock/removeStock/transferStock.
func stocktakeCellSubmit(ctx context.Context, q Querier, in model.StocktakeCellSubmitInput) (model.StocktakeCellResult, error) {
	c, err := lockStocktakeCell(ctx, q, in.StocktakeCellID, 0)
	if err != nil {
		return model.StocktakeCellResult{}, err
	}
	if !c.mine(in.UserID) {
		return model.StocktakeCellResult{}, model.ErrStocktakeCellNotYours
	}
	switch c.status {
	case model.StocktakeCellCounting:
	case model.StocktakeCellDisrupted:
		return model.StocktakeCellResult{}, model.ErrStocktakeCellDisrupted
	case model.StocktakeCellCounted:
		return model.StocktakeCellResult{}, model.ErrStocktakeCellCounted
	default:
		return model.StocktakeCellResult{}, model.ErrStocktakeCellNotCounting
	}
	if _, err := q.Exec(ctx, `
		UPDATE stocktake_cells SET status = 'counted', counted_by = $2::uuid, counted_at = now()
		WHERE id = $1::uuid`, in.StocktakeCellID, in.UserID); err != nil {
		return model.StocktakeCellResult{}, fmt.Errorf("ячейка подсчитана: %w", err)
	}

	sc := &stocktakeCount{q: q, c: c, id: in.StocktakeCellID, user: in.UserID}
	if err := sc.load(ctx); err != nil {
		return model.StocktakeCellResult{}, err
	}
	if err := sc.guardArea(ctx, in); err != nil {
		return model.StocktakeCellResult{}, err
	}
	if err := sc.countBoxes(ctx, in.Boxes); err != nil {
		return model.StocktakeCellResult{}, err
	}
	for _, f := range in.Loose {
		if err := sc.countLoose(ctx, f); err != nil {
			return model.StocktakeCellResult{}, err
		}
	}
	if err := sc.marksNotFound(ctx); err != nil {
		return model.StocktakeCellResult{}, err
	}
	if err := sc.adjust(ctx); err != nil {
		return model.StocktakeCellResult{}, err
	}
	return sc.res, nil
}

// load читает строки снимка и склад «Не найдено».
func (sc *stocktakeCount) load(ctx context.Context) error {
	if err := sc.q.QueryRow(ctx, `SELECT id::text FROM internal_warehouses WHERE system_role = 'not_found'`).
		Scan(&sc.notFound); err != nil {
		return fmt.Errorf("склад «Не найдено»: %w", err)
	}
	rows, err := sc.q.Query(ctx, `
		SELECT id::text, COALESCE(load_unit_id::text, ''), COALESCE(good_id::text, ''),
		       COALESCE(batch_id::text, ''), internal_warehouse_id::text
		FROM stocktake_lines WHERE stocktake_cell_id = $1::uuid`, sc.id)
	if err != nil {
		return fmt.Errorf("строки снимка: %w", err)
	}
	defer rows.Close()
	sc.loose = map[stocktakeLineKey]*stocktakeLine{}
	sc.boxes = map[string]*stocktakeLine{}
	for rows.Next() {
		l := &stocktakeLine{}
		if err := rows.Scan(&l.id, &l.loadUnit, &l.good, &l.batch, &l.iwh); err != nil {
			return fmt.Errorf("разобрать строку снимка: %w", err)
		}
		switch {
		case l.good == "":
			sc.boxes[l.loadUnit] = l
		case l.loadUnit == "":
			sc.loose[stocktakeLineKey{l.good, l.batch, l.iwh}] = l
		}
	}
	return rows.Err()
}

// guardArea - при области по группе, поставщику, товару в факте только товар области.
func (sc *stocktakeCount) guardArea(ctx context.Context, in model.StocktakeCellSubmitInput) error {
	if !model.StocktakeCountsAreaGoodsOnly(sc.c.scopeKind) || len(in.Loose) == 0 {
		return nil
	}
	goods := make([]string, 0, len(in.Loose))
	for _, f := range in.Loose {
		goods = append(goods, f.GoodID)
	}
	var outside bool
	if err := sc.q.QueryRow(ctx, `
		SELECT EXISTS (SELECT 1 FROM unnest($2::text[]::uuid[]) g(id)
		               WHERE g.id NOT IN (`+stocktakeAreaGoodsSQL+`))`, sc.c.stocktake, goods).
		Scan(&outside); err != nil {
		return fmt.Errorf("товар области: %w", err)
	}
	if outside {
		return model.ErrStocktakeOutOfArea
	}
	return nil
}

// countBoxes - короба: найденный из снимка подтверждён, учётный из другой ячейки переносится
// сюда, неизвестный - отказ; ожидавшийся и не найденный уходит в «Не найдено».
func (sc *stocktakeCount) countBoxes(ctx context.Context, found []string) error {
	for _, lu := range found {
		if l, ok := sc.boxes[lu]; ok {
			l.fact = decimal.NewFromInt(1)
			continue
		}
		if err := sc.foreignBox(ctx, lu); err != nil {
			return err
		}
	}
	for lu, l := range sc.boxes {
		if l.foreign {
			continue
		}
		if err := sc.boxContentLines(ctx, l, true, l.fact.IsPositive()); err != nil {
			return err
		}
		if l.fact.IsPositive() {
			continue
		}
		problem, err := sc.notFoundProblem(ctx, ProblemSubmitInput{LoadUnitID: lu})
		if err != nil {
			return err
		}
		if _, err := sc.q.Exec(ctx, `UPDATE stocktake_lines SET problem_id = $2::uuid WHERE id = $1::uuid`,
			l.id, problem); err != nil {
			return fmt.Errorf("проблема короба в снимке: %w", err)
		}
	}
	return nil
}

// foreignBox - найденный короб не из снимка. В WMS он есть и лежит в другой ячейке - пересчёт
// переносит его сюда строкой журнала размещений; нет в WMS - его заводят приёмкой или «Вводом
// остатков»; короб на системном складе - в решении офиса или задании, пересчёт его не трогает.
func (sc *stocktakeCount) foreignBox(ctx context.Context, lu string) error {
	var cell *string
	var iwh string
	var system, live bool
	err := sc.q.QueryRow(ctx, `
		SELECT lu.cell_id::text, lu.internal_warehouse_id::text, w.system_role IS NOT NULL,
		       EXISTS (SELECT 1 FROM lu_content x WHERE x.load_unit_id = lu.id AND x.qty > 0)
		FROM load_units lu JOIN internal_warehouses w ON w.id = lu.internal_warehouse_id
		WHERE lu.id = $1::uuid`, lu).Scan(&cell, &iwh, &system, &live)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && (cell == nil || !live)) {
		return model.ErrStocktakeUnknownBox
	}
	if err != nil {
		return fmt.Errorf("найденный короб: %w", err)
	}
	if system {
		return model.ErrStocktakeInProblem
	}
	if *cell != sc.c.cell {
		if err := guardNotReceivingCell(ctx, sc.q, *cell); err != nil {
			return err
		}
		if _, _, err := transferLoadUnit(ctx, sc.q, loadUnitTransfer{
			LoadUnitID: lu, ToCellID: sc.c.cell, WarehouseID: sc.c.warehouse,
			Source: model.PlacementStocktake, UserID: sc.user, StocktakeCellID: &sc.id,
		}); err != nil {
			return err
		}
		sc.res.MovedBoxes++
	}
	var id string
	if err := sc.q.QueryRow(ctx, `
		INSERT INTO stocktake_lines (stocktake_cell_id, load_unit_id, internal_warehouse_id, expected_qty, fact_qty)
		VALUES ($1::uuid, $2::uuid, $3::uuid, 0, 1)
		RETURNING id::text`, sc.id, lu, iwh).Scan(&id); err != nil {
		return fmt.Errorf("излишек короба: %w", err)
	}
	l := &stocktakeLine{id: id, loadUnit: lu, iwh: iwh, fact: decimal.NewFromInt(1), foreign: true}
	sc.boxes[lu] = l
	return sc.boxContentLines(ctx, l, false, true)
}

// boxContentLines пишет состав короба строками «товар в коробе» (P10-05): документ
// «Инвентаризация» разворачивает короба в товар - 1С знает товар, а не короба. Ожидалось -
// состав, если короб был в снимке; факт - состав, если короб найден. Состав читается в момент
// подсчёта: пока ячейка на подсчёте, он не менялся (иначе подсчёт сбит), а проблема «не найдено»
// и перенос короба его не трогают.
func (sc *stocktakeCount) boxContentLines(ctx context.Context, l *stocktakeLine, expected, found bool) error {
	if _, err := sc.q.Exec(ctx, `
		INSERT INTO stocktake_lines
			(stocktake_cell_id, load_unit_id, good_id, batch_id, internal_warehouse_id, expected_qty, fact_qty)
		SELECT $1::uuid, c.load_unit_id, c.good_id, c.batch_id, $3::uuid,
		       CASE WHEN $4 THEN c.qty ELSE 0 END, CASE WHEN $5 THEN c.qty ELSE 0 END
		FROM lu_content c
		WHERE c.load_unit_id = $2::uuid AND c.qty > 0`, sc.id, l.loadUnit, l.iwh, expected, found); err != nil {
		return fmt.Errorf("состав короба в подсчёте: %w", err)
	}
	return nil
}

// countLoose - факт россыпи позиции: строка снимка или новая (излишек) с фактом; найденные
// марки отмечаются, марка из другого места переносится сюда вместе с единицей остатка.
func (sc *stocktakeCount) countLoose(ctx context.Context, f model.StocktakeLooseFact) error {
	iwh := f.InternalWarehouseID
	if iwh == "" {
		var err error
		if iwh, err = defaultInternalWarehouse(ctx, sc.q); err != nil {
			return err
		}
	}
	if err := guardActiveInternalWarehouse(ctx, sc.q, iwh); err != nil {
		return err
	}
	var marked bool
	err := sc.q.QueryRow(ctx, `SELECT cz_marked FROM goods WHERE id = $1::uuid`, f.GoodID).Scan(&marked)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrUnknownReference
	}
	if err != nil {
		return fmt.Errorf("товар факта: %w", err)
	}
	if marked && len(f.Marks) == 0 && f.Qty.IsPositive() {
		return model.ErrStocktakeMarksRequired
	}
	if len(f.Marks) > 0 && !f.Qty.Equal(decimal.NewFromInt(int64(len(f.Marks)))) {
		return model.ErrCZMarksQtyMismatch
	}
	batch, err := getOrCreateBatch(ctx, sc.q, f.GoodID, f.ProductionDate)
	if err != nil {
		return err
	}
	key := stocktakeLineKey{f.GoodID, batch, iwh}
	l, ok := sc.loose[key]
	if !ok {
		var id string
		if err := sc.q.QueryRow(ctx, `
			INSERT INTO stocktake_lines (stocktake_cell_id, good_id, batch_id, internal_warehouse_id, expected_qty)
			VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, 0)
			RETURNING id::text`, sc.id, f.GoodID, batch, iwh).Scan(&id); err != nil {
			return fmt.Errorf("излишек россыпи: %w", err)
		}
		l = &stocktakeLine{id: id, good: f.GoodID, batch: batch, iwh: iwh}
		sc.loose[key] = l
	}
	l.fact = f.Qty
	for _, cis := range f.Marks {
		if err := sc.foundMark(ctx, l, cis); err != nil {
			return err
		}
	}
	return nil
}

// foundMark отмечает найденную марку. Ожидалась на этой строке - найдена; лежит на складе в
// другом месте - единица остатка и марка переносятся сюда: её нашли здесь. Марки нет на складе
// или она в проблеме - отказ: судьбу такой марки решает приёмка или офис, а не пересчёт.
func (sc *stocktakeCount) foundMark(ctx context.Context, l *stocktakeLine, cis string) error {
	tag, err := sc.q.Exec(ctx, `
		UPDATE stocktake_marks SET found = true
		WHERE stocktake_cell_id = $1::uuid AND cis = $2 AND line_id = $3::uuid`, sc.id, cis, l.id)
	if err != nil {
		return fmt.Errorf("найденная марка: %w", err)
	}
	if tag.RowsAffected() > 0 {
		return nil
	}

	var good, batch, status string
	var lu, cell, iwh, problem *string
	err = sc.q.QueryRow(ctx, `
		SELECT m.good_id::text, m.batch_id::text, m.status, m.load_unit_id::text, m.cell_id::text,
		       COALESCE(m.internal_warehouse_id, lu.internal_warehouse_id)::text, m.problem_id::text
		FROM cz_marks m LEFT JOIN load_units lu ON lu.id = m.load_unit_id
		WHERE m.cis = $1`, cis).Scan(&good, &batch, &status, &lu, &cell, &iwh, &problem)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && status != model.CZMarkInStock) {
		return model.ErrStocktakeUnknownMark
	}
	if err != nil {
		return fmt.Errorf("найденная марка: %w", err)
	}
	if good != l.good || batch != l.batch {
		return model.ErrCZMarkBatchMismatch
	}
	if problem != nil {
		var open bool
		if err := sc.q.QueryRow(ctx, `SELECT status = 'open' FROM warehouse_problems WHERE id = $1::uuid`,
			*problem).Scan(&open); err != nil {
			return fmt.Errorf("проблема марки: %w", err)
		}
		if open {
			return model.ErrStocktakeInProblem
		}
	}

	from := placeOf(deref(lu), deref(cell), deref(iwh))
	one := decimal.NewFromInt(1)
	fromCell := deref(cell)
	if lu != nil {
		if err := sc.q.QueryRow(ctx, `SELECT cell_id::text FROM load_units WHERE id = $1::uuid`, *lu).
			Scan(&fromCell); err != nil {
			return fmt.Errorf("короб марки: %w", err)
		}
		if err := takeFromLoadUnit(ctx, sc.q, *lu, good, batch, one); err != nil {
			return err
		}
	}
	if err := transferStock(ctx, sc.q,
		model.StockKey{CellID: fromCell, GoodID: good, BatchID: batch, InternalWarehouseID: deref(iwh)},
		model.StockKey{CellID: sc.c.cell, GoodID: good, BatchID: batch, InternalWarehouseID: l.iwh},
		one); err != nil {
		return err
	}
	if err := moveMarks(ctx, sc.q, good, batch, []string{cis}, one, from, placeOf("", sc.c.cell, l.iwh)); err != nil {
		return err
	}
	if _, err := sc.q.Exec(ctx, `
		INSERT INTO stocktake_marks (stocktake_cell_id, cis, line_id, expected, found)
		VALUES ($1::uuid, $2, $3::uuid, false, true)
		ON CONFLICT (stocktake_cell_id, cis) DO UPDATE SET line_id = EXCLUDED.line_id, found = true`,
		sc.id, cis, l.id); err != nil {
		return fmt.Errorf("излишек марки: %w", err)
	}
	return nil
}

// marksNotFound - ожидавшиеся и не найденные марки россыпью уходят в «Не найдено» одной
// проблемой на позицию: марки, количество - их число.
func (sc *stocktakeCount) marksNotFound(ctx context.Context) error {
	rows, err := sc.q.Query(ctx, `
		SELECT m.line_id::text, m.cis FROM stocktake_marks m
		WHERE m.stocktake_cell_id = $1::uuid AND m.expected AND NOT m.found
		ORDER BY m.line_id, m.cis`, sc.id)
	if err != nil {
		return fmt.Errorf("не найденные марки: %w", err)
	}
	missing := map[string][]string{}
	var order []string
	for rows.Next() {
		var line, cis string
		if err := rows.Scan(&line, &cis); err != nil {
			rows.Close()
			return fmt.Errorf("разобрать не найденную марку: %w", err)
		}
		if _, ok := missing[line]; !ok {
			order = append(order, line)
		}
		missing[line] = append(missing[line], cis)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return fmt.Errorf("не найденные марки: %w", err)
	}

	byID := map[string]*stocktakeLine{}
	for _, l := range sc.loose {
		byID[l.id] = l
	}
	for _, lineID := range order {
		l := byID[lineID]
		marks := missing[lineID]
		var date string
		if err := sc.q.QueryRow(ctx, `SELECT production_date::text FROM batches WHERE id = $1::uuid`, l.batch).
			Scan(&date); err != nil {
			return fmt.Errorf("партия марок: %w", err)
		}
		problem, err := sc.notFoundProblem(ctx, ProblemSubmitInput{
			GoodID: l.good, ProductionDate: date, Qty: decimal.NewFromInt(int64(len(marks))),
			CellID: sc.c.cell, FromInternalWarehouseID: l.iwh, Marks: marks,
		})
		if err != nil {
			return err
		}
		if _, err := sc.q.Exec(ctx, `
			UPDATE stocktake_marks SET problem_id = $3::uuid
			WHERE stocktake_cell_id = $1::uuid AND cis = ANY($2::text[])`, sc.id, marks, problem); err != nil {
			return fmt.Errorf("проблема марок в снимке: %w", err)
		}
	}
	return nil
}

// notFoundProblem заводит проблему склада «не найдено»: короб или товар уходит на склад
// «Не найдено» той же ячейки, решение - за офисом.
func (sc *stocktakeCount) notFoundProblem(ctx context.Context, in ProblemSubmitInput) (string, error) {
	in.ProblemID = uuid.NewString()
	in.WarehouseID = sc.c.warehouse
	in.CreatedBy = sc.user
	in.ToInternalWarehouseID = sc.notFound
	in.Reason = model.ProblemReasonNotFound
	in.Comment = "Пересчёт №" + strconv.FormatInt(sc.c.number, 10)
	in.fromStocktake = true
	if err := problemSubmit(ctx, sc.q, in); err != nil {
		return "", err
	}
	sc.res.Problems++
	return in.ProblemID, nil
}

// adjust пишет факт в строки и приводит россыпь каждой позиции к факту - разницей с россыпью
// после проблем и переносов; каждая правка - строкой audit_log.
func (sc *stocktakeCount) adjust(ctx context.Context) error {
	for _, l := range sc.boxes {
		if _, err := sc.q.Exec(ctx, `UPDATE stocktake_lines SET fact_qty = $2::numeric WHERE id = $1::uuid`,
			l.id, l.fact.String()); err != nil {
			return fmt.Errorf("факт короба: %w", err)
		}
	}
	for _, l := range sc.loose {
		if _, err := sc.q.Exec(ctx, `UPDATE stocktake_lines SET fact_qty = $2::numeric WHERE id = $1::uuid`,
			l.id, l.fact.String()); err != nil {
			return fmt.Errorf("факт россыпи: %w", err)
		}
		before, err := looseQty(ctx, sc.q, sc.c.cell, l.good, l.batch, l.iwh)
		if err != nil {
			return err
		}
		delta := l.fact.Sub(before)
		key := model.StockKey{CellID: sc.c.cell, GoodID: l.good, BatchID: l.batch, InternalWarehouseID: l.iwh}
		switch {
		case delta.IsZero():
			continue
		case delta.IsPositive():
			err = addStock(ctx, sc.q, key, delta)
		default:
			err = removeStock(ctx, sc.q, key, delta.Neg())
		}
		if err != nil {
			return err
		}
		if err := sc.audit(ctx, l, before); err != nil {
			return err
		}
		sc.res.Adjustments++
	}
	return nil
}

// audit пишет правку остатка пересчётом в audit_log: что, где, было и стало, кто.
func (sc *stocktakeCount) audit(ctx context.Context, l *stocktakeLine, before decimal.Decimal) error {
	details, err := json.Marshal(map[string]string{
		"stocktake_id": sc.c.stocktake, "stocktake_cell_id": sc.id, "cell_id": sc.c.cell,
		"good_id": l.good, "batch_id": l.batch, "internal_warehouse_id": l.iwh,
		"before": before.String(), "after": l.fact.String(),
	})
	if err != nil {
		return fmt.Errorf("правка пересчёта для журнала: %w", err)
	}
	if _, err := sc.q.Exec(ctx, `
		INSERT INTO audit_log (user_id, action, entity_type, entity_id, details)
		VALUES ($1::uuid, 'stocktake.adjust', 'stocktake_line', $2, $3::jsonb)`,
		sc.user, l.id, string(details)); err != nil {
		return fmt.Errorf("журнал правки пересчёта: %w", err)
	}
	return nil
}
