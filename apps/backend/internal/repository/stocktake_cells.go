package repository

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"craftwms/internal/model"
)

// stocktakeCellSelect — ячейка пересчёта, как её видит $1: зависшая чужая взятая (не начата
// дольше срока $2) показывается свободной — её снова можно взять.
const stocktakeCellSelect = `
	SELECT sc.id::text, sc.stocktake_id::text, sc.cell_id::text, c.address,
	       CASE WHEN sc.status = 'taken' AND sc.taken_by <> $1::uuid
	                 AND sc.taken_at < now() - $2::interval THEN 'pending'
	            ELSE sc.status END,
	       COALESCE(u.full_name, ''), sc.taken_at, sc.started_at, sc.counted_at,
	       COALESCE(sc.taken_by = $1::uuid, false)
	FROM stocktake_cells sc
	JOIN cells c ON c.id = sc.cell_id
	LEFT JOIN users u ON u.id = sc.taken_by`

func scanStocktakeCells(rows pgx.Rows) ([]model.StocktakeCell, error) {
	defer rows.Close()
	var out []model.StocktakeCell
	for rows.Next() {
		var c model.StocktakeCell
		if err := rows.Scan(&c.ID, &c.StocktakeID, &c.CellID, &c.Address, &c.Status, &c.TakenByName,
			&c.TakenAt, &c.StartedAt, &c.CountedAt, &c.Mine); err != nil {
			return nil, fmt.Errorf("разобрать ячейку пересчёта: %w", err)
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// Get возвращает пересчёт с ходом выполнения: шапку и все его ячейки (P10-03).
func (r *StocktakeRepository) Get(ctx context.Context, id, userID string, staleAfter time.Duration) (model.Stocktake, error) {
	var st model.Stocktake
	err := r.pool.QueryRow(ctx, `
		SELECT st.id::text, st.number, st.warehouse_id::text, st.scope_kind, st.status,
		       COALESCE(t.id::text, ''), COALESCE(u.full_name, ''), st.created_at, st.closed_at
		FROM stocktakes st
		LEFT JOIN warehouse_tasks t ON t.stocktake_id = st.id
		LEFT JOIN users u ON u.id = st.created_by
		WHERE st.id = $1::uuid`, id).
		Scan(&st.ID, &st.Number, &st.WarehouseID, &st.ScopeKind, &st.Status, &st.TaskID,
			&st.CreatedByName, &st.CreatedAt, &st.ClosedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return model.Stocktake{}, model.ErrStocktakeNotFound
	}
	if err != nil {
		return model.Stocktake{}, fmt.Errorf("пересчёт: %w", err)
	}
	rows, err := r.pool.Query(ctx, stocktakeCellSelect+`
		WHERE sc.stocktake_id = $3::uuid ORDER BY c.address`, userID, intervalOf(staleAfter), id)
	if err != nil {
		return model.Stocktake{}, fmt.Errorf("ячейки пересчёта: %w", err)
	}
	if st.Cells, err = scanStocktakeCells(rows); err != nil {
		return model.Stocktake{}, err
	}
	return st, nil
}

// Cells возвращает ячейки пересчёта, которые работник может считать: свободные (и зависшие
// чужие) и свои — взятые, на подсчёте, сбитые. Подсчитанные и чужие в работе не показываются:
// к ним не пойдут.
func (r *StocktakeRepository) Cells(ctx context.Context, stocktakeID, userID string, staleAfter time.Duration) ([]model.StocktakeCell, error) {
	if err := guardStocktakeExists(ctx, r.pool, stocktakeID); err != nil {
		return nil, err
	}
	rows, err := r.pool.Query(ctx, `SELECT * FROM (`+stocktakeCellSelect+`
		WHERE sc.stocktake_id = $3::uuid) v (id, stocktake_id, cell_id, address, status, taken_by_name,
		                                      taken_at, started_at, counted_at, mine)
		WHERE v.status = 'pending' OR (v.mine AND v.status <> 'counted')
		ORDER BY v.address`, userID, intervalOf(staleAfter), stocktakeID)
	if err != nil {
		return nil, fmt.Errorf("ячейки пересчёта работника: %w", err)
	}
	return scanStocktakeCells(rows)
}

func guardStocktakeExists(ctx context.Context, q Querier, id string) error {
	var ok bool
	if err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM stocktakes WHERE id = $1::uuid)`, id).
		Scan(&ok); err != nil {
		return fmt.Errorf("пересчёт: %w", err)
	}
	if !ok {
		return model.ErrStocktakeNotFound
	}
	return nil
}

// lockedStocktakeCell — ячейка пересчёта под блокировкой с состоянием её пересчёта.
type lockedStocktakeCell struct {
	cell, status, stocktake, stocktakeStatus, scopeKind, warehouse string
	number                                                         int64
	takenBy                                                        *string
	stale                                                          bool
}

// lockStocktakeCell блокирует строку ячейки пересчёта. Зависшая — взята, не начата и держится
// дольше staleAfter.
func lockStocktakeCell(ctx context.Context, q Querier, id string, staleAfter time.Duration) (lockedStocktakeCell, error) {
	var c lockedStocktakeCell
	err := q.QueryRow(ctx, `
		SELECT sc.cell_id::text, sc.status, sc.taken_by::text,
		       COALESCE(sc.status = 'taken' AND sc.taken_at < now() - $2::interval, false),
		       st.id::text, st.status, st.scope_kind, st.warehouse_id::text, st.number
		FROM stocktake_cells sc
		JOIN stocktakes st ON st.id = sc.stocktake_id
		WHERE sc.id = $1::uuid
		FOR UPDATE OF sc`, id, intervalOf(staleAfter)).
		Scan(&c.cell, &c.status, &c.takenBy, &c.stale, &c.stocktake, &c.stocktakeStatus, &c.scopeKind,
			&c.warehouse, &c.number)
	if errors.Is(err, pgx.ErrNoRows) {
		return c, model.ErrStocktakeCellNotFound
	}
	if err != nil {
		return c, fmt.Errorf("ячейка пересчёта: %w", err)
	}
	if c.stocktakeStatus == stocktakeClosed {
		return c, model.ErrStocktakeClosed
	}
	return c, nil
}

// stocktakeClosed — статус закрытого пересчёта.
const stocktakeClosed = "closed"

// mine — ячейку держит этот работник.
func (c lockedStocktakeCell) mine(userID string) bool {
	return c.takenBy != nil && *c.takenBy == userID
}

// Take отдаёт ячейку пересчёта работнику (P10-03) — только со связью: кто держит ячейку, знает
// сервер, иначе двое пошли бы к одной полке.
//
// Свободную и зависшую чужую — берёт; свою — повтор, не ошибка; чужую в работе — отказ.
func (r *StocktakeRepository) Take(ctx context.Context, id, userID string, staleAfter time.Duration) error {
	return WithinTx(ctx, r.pool, func(q Querier) error {
		c, err := lockStocktakeCell(ctx, q, id, staleAfter)
		if err != nil {
			return err
		}
		switch {
		case c.status == model.StocktakeCellCounted:
			return model.ErrStocktakeCellCounted
		case c.mine(userID):
			return nil
		case c.status != model.StocktakeCellPending && !c.stale:
			return model.ErrStocktakeCellBusy
		}
		if _, err := q.Exec(ctx, `
			UPDATE stocktake_cells SET status = 'taken', taken_by = $2::uuid, taken_at = now()
			WHERE id = $1::uuid`, id, userID); err != nil {
			return fmt.Errorf("взять ячейку пересчёта: %w", err)
		}
		return nil
	})
}

// Release возвращает свою ячейку пересчёта в общий список (P10-03). Начатый подсчёт
// отбрасывается вместе со снимком: следующий работник снимет свой. Ячейка уже свободна — повтор.
func (r *StocktakeRepository) Release(ctx context.Context, id, userID string) error {
	return WithinTx(ctx, r.pool, func(q Querier) error {
		c, err := lockStocktakeCell(ctx, q, id, 0)
		if err != nil {
			return err
		}
		switch {
		case c.status == model.StocktakeCellCounted:
			return model.ErrStocktakeCellCounted
		case c.status == model.StocktakeCellPending:
			return nil
		case !c.mine(userID):
			return model.ErrStocktakeCellNotYours
		}
		if _, err := q.Exec(ctx, `DELETE FROM stocktake_lines WHERE stocktake_cell_id = $1::uuid`, id); err != nil {
			return fmt.Errorf("сбросить подсчёт ячейки: %w", err)
		}
		if _, err := q.Exec(ctx, `
			UPDATE stocktake_cells
			SET status = 'pending', taken_by = NULL, taken_at = NULL, started_at = NULL
			WHERE id = $1::uuid`, id); err != nil {
			return fmt.Errorf("вернуть ячейку пересчёта: %w", err)
		}
		return nil
	})
}

// CellView возвращает свою ячейку пересчёта с позициями снимка (P10-03): что искать, без
// количеств — слепой счёт. Позиции есть, пока ячейка на подсчёте.
func (r *StocktakeRepository) CellView(ctx context.Context, id, userID string) (model.StocktakeCellView, error) {
	rows, err := r.pool.Query(ctx, stocktakeCellSelect+` WHERE sc.id = $3::uuid`, userID, intervalOf(0), id)
	if err != nil {
		return model.StocktakeCellView{}, fmt.Errorf("ячейка пересчёта: %w", err)
	}
	cells, err := scanStocktakeCells(rows)
	if err != nil {
		return model.StocktakeCellView{}, err
	}
	if len(cells) == 0 {
		return model.StocktakeCellView{}, model.ErrStocktakeCellNotFound
	}
	if !cells[0].Mine {
		return model.StocktakeCellView{}, model.ErrStocktakeCellNotYours
	}
	out := model.StocktakeCellView{StocktakeCell: cells[0]}
	if out.Positions, err = stocktakePositions(ctx, r.pool, id); err != nil {
		return model.StocktakeCellView{}, err
	}
	return out, nil
}

// stocktakePositions — позиции снимка ячейки пересчёта: короба, затем россыпь по товару и партии.
func stocktakePositions(ctx context.Context, q Querier, stocktakeCellID string) ([]model.StocktakePosition, error) {
	rows, err := q.Query(ctx, `
		SELECT l.load_unit_id::text, cza.code, l.good_id::text, COALESCE(g.code, ''),
		       COALESCE(g.name, ''), COALESCE(g.uom, ''), b.production_date,
		       COALESCE(g.cz_marked, false), l.internal_warehouse_id::text
		FROM stocktake_lines l
		LEFT JOIN goods g   ON g.id = l.good_id
		LEFT JOIN batches b ON b.id = l.batch_id
		LEFT JOIN cz_aggregates cza ON cza.load_unit_id = l.load_unit_id
		WHERE l.stocktake_cell_id = $1::uuid
		ORDER BY l.good_id IS NOT NULL, g.name, b.production_date, l.load_unit_id`, stocktakeCellID)
	if err != nil {
		return nil, fmt.Errorf("позиции снимка: %w", err)
	}
	defer rows.Close()
	var out []model.StocktakePosition
	for rows.Next() {
		var p model.StocktakePosition
		if err := rows.Scan(&p.LoadUnitID, &p.CZCode, &p.GoodID, &p.GoodCode, &p.GoodName, &p.Uom,
			&p.ProductionDate, &p.Marked, &p.InternalWarehouseID); err != nil {
			return nil, fmt.Errorf("разобрать позицию снимка: %w", err)
		}
		p.Kind = model.StocktakePositionLoose
		if p.GoodID == nil {
			p.Kind = model.StocktakePositionBox
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// Close закрывает пересчёт (P10-03): задание уходит в «Завершённые», в портал — документ
// «Инвентаризация» (P10-05).
//
// Остаток к факту приводит подсчёт каждой ячейки, а не закрытие: закрытие подводит итог.
// Неподсчитанные ячейки остаются как были и остаток не трогают; закрыть с ними можно только
// с подтверждением (force). Возвращает, сколько ячеек осталось неподсчитанными.
func (r *StocktakeRepository) Close(ctx context.Context, id, userID string, force bool) (int, error) {
	var uncounted int
	err := WithinTx(ctx, r.pool, func(q Querier) error {
		var status string
		err := q.QueryRow(ctx, `SELECT status FROM stocktakes WHERE id = $1::uuid FOR UPDATE`, id).Scan(&status)
		if errors.Is(err, pgx.ErrNoRows) {
			return model.ErrStocktakeNotFound
		}
		if err != nil {
			return fmt.Errorf("пересчёт: %w", err)
		}
		if status == stocktakeClosed {
			return model.ErrStocktakeClosed
		}
		if err := q.QueryRow(ctx, `
			SELECT count(*) FROM stocktake_cells WHERE stocktake_id = $1::uuid AND status <> 'counted'`, id).
			Scan(&uncounted); err != nil {
			return fmt.Errorf("неподсчитанные ячейки: %w", err)
		}
		if uncounted > 0 && !force {
			return model.ErrStocktakeUncounted
		}
		if _, err := q.Exec(ctx, `
			UPDATE stocktakes SET status = 'closed', closed_by = $2::uuid, closed_at = now()
			WHERE id = $1::uuid`, id, userID); err != nil {
			return fmt.Errorf("закрыть пересчёт: %w", err)
		}
		// Документ «Инвентаризация» для 1С (P10-05) — в той же транзакции: закрытый пересчёт без
		// документа невозможен, как и документ по незакрытому.
		if err := saveStocktakeDocument(ctx, q, id, userID); err != nil {
			return err
		}
		var taskID string
		if err := q.QueryRow(ctx, `
			UPDATE warehouse_tasks SET status = 'done', completed_by = $2::uuid, completed_at = now()
			WHERE stocktake_id = $1::uuid
			RETURNING id::text`, id, userID).Scan(&taskID); err != nil {
			return fmt.Errorf("завершить задание пересчёта: %w", err)
		}
		return addTaskEvent(ctx, q, taskID, model.TaskEventCompleted, userID, "", "")
	})
	if err != nil {
		return 0, err
	}
	return uncounted, nil
}

// List — пересчёты для портала (P10-05): открытые сверху, свежие первыми; status — `open`
// (не закрытые), `closed` или пусто — все.
func (r *StocktakeRepository) List(ctx context.Context, status string) ([]model.StocktakeListItem, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT st.id::text, st.number, st.scope_kind, st.status, COALESCE(u.full_name, ''),
		       st.created_at, st.closed_at,
		       count(sc.id), count(sc.id) FILTER (WHERE sc.status = 'counted')
		FROM stocktakes st
		LEFT JOIN users u ON u.id = st.created_by
		LEFT JOIN stocktake_cells sc ON sc.stocktake_id = st.id
		WHERE $1 = '' OR ($1 = 'open' AND st.status <> 'closed') OR ($1 = 'closed' AND st.status = 'closed')
		GROUP BY st.id, u.full_name
		ORDER BY (st.status = 'closed'), st.created_at DESC`, status)
	if err != nil {
		return nil, fmt.Errorf("список пересчётов: %w", err)
	}
	defer rows.Close()
	out := []model.StocktakeListItem{}
	for rows.Next() {
		var it model.StocktakeListItem
		if err := rows.Scan(&it.ID, &it.Number, &it.ScopeKind, &it.Status, &it.CreatedByName,
			&it.CreatedAt, &it.ClosedAt, &it.Cells, &it.Counted); err != nil {
			return nil, fmt.Errorf("разобрать пересчёт: %w", err)
		}
		out = append(out, it)
	}
	return out, rows.Err()
}
