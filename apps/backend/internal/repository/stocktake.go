package repository

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/model"
)

// StocktakeRepository — пересчёт (P10): заведение по области и снимок ячейки в начале подсчёта.
type StocktakeRepository struct {
	pool *pgxpool.Pool
}

// NewStocktakeRepository создаёт репозиторий пересчёта.
func NewStocktakeRepository(pool *pgxpool.Pool) *StocktakeRepository {
	return &StocktakeRepository{pool: pool}
}

// stocktakeScopeColumn — колонка `stocktake_scope` для объектов вида области. У «всего склада»
// объектов нет.
var stocktakeScopeColumn = map[string]string{
	model.StocktakeScopeCells:             "cell_id",
	model.StocktakeScopeGroup:             "group_id",
	model.StocktakeScopeSupplier:          "supplier_id",
	model.StocktakeScopeGood:              "good_id",
	model.StocktakeScopeInternalWarehouse: "internal_warehouse_id",
}

// stocktakeAreaGoodsSQL — товары области пересчёта $1: выбранные товары, товары выбранных
// поставщиков и товары групп с поддеревом (матрица — узел того же дерева). У пересчёта один вид
// области, поэтому условия объединяются: лишние подзапросы пусты.
const stocktakeAreaGoodsSQL = `
	SELECT g.id FROM goods g
	WHERE g.id IN (SELECT good_id FROM stocktake_scope WHERE stocktake_id = $1::uuid AND good_id IS NOT NULL)
	   OR g.supplier_id IN (SELECT supplier_id FROM stocktake_scope
	                        WHERE stocktake_id = $1::uuid AND supplier_id IS NOT NULL)
	   OR g.group_id IN (
	        WITH RECURSIVE tree AS (
	            SELECT group_id AS id FROM stocktake_scope WHERE stocktake_id = $1::uuid AND group_id IS NOT NULL
	            UNION
	            SELECT ng.id FROM nomenclature_groups ng JOIN tree ON ng.parent_id = tree.id)
	        SELECT id FROM tree)`

// stocktakeCellsSQL — условие на ячейку `c` для каждого вида области пересчёта $1.
//
// Ячейки и «весь склад» — как заданы; внутренний склад, группа, поставщик и товар — ячейки, где
// сейчас есть их остаток. Остаток ячейки включает содержимое её коробов, поэтому товар в коробе
// ячейку тоже даёт. Ячейка приёмки отсекается общим условием в Create.
var stocktakeCellsSQL = map[string]string{
	model.StocktakeScopeCells: `c.id IN (SELECT cell_id FROM stocktake_scope WHERE stocktake_id = $1::uuid)`,
	model.StocktakeScopeAll:   `true`,
	model.StocktakeScopeInternalWarehouse: `EXISTS (
		SELECT 1 FROM stock s WHERE s.cell_id = c.id AND s.qty > 0
		  AND s.internal_warehouse_id IN (SELECT internal_warehouse_id FROM stocktake_scope
		                                  WHERE stocktake_id = $1::uuid))`,
	model.StocktakeScopeGroup:    stocktakeCellsWithAreaGoods,
	model.StocktakeScopeSupplier: stocktakeCellsWithAreaGoods,
	model.StocktakeScopeGood:     stocktakeCellsWithAreaGoods,
}

const stocktakeCellsWithAreaGoods = `EXISTS (
	SELECT 1 FROM stock s WHERE s.cell_id = c.id AND s.qty > 0 AND s.good_id IN (` + stocktakeAreaGoodsSQL + `))`

// Create заводит пересчёт: шапку, объекты области, ячейки и общее задание в пуле (P10-02).
//
// Что: область разворачивается в ячейки сразу — каждая `pending`, её возьмёт любой работник.
// Зачем: список ячеек — это объём работы, его видит старший смены и пул заданий. Снимка
// «ожидалось» здесь нет: он снимается при начале подсчёта ячейки (StartCount), иначе за время
// между заведением и подсчётом движения дали бы ложные расхождения (решение 2026-10-26).
// Как: одной транзакцией. Ячейка приёмки в пересчёт не входит — её товар ждёт размещения;
// выбранная явно — отказ. Область без ячеек — отказ: пустой пересчёт ничего не считает.
func (r *StocktakeRepository) Create(ctx context.Context, in model.StocktakeCreateInput) (model.StocktakeCreated, error) {
	where, ok := stocktakeCellsSQL[in.ScopeKind]
	if !ok {
		return model.StocktakeCreated{}, model.ErrInvalidStocktake
	}
	var out model.StocktakeCreated
	err := WithinTx(ctx, r.pool, func(q Querier) error {
		if err := q.QueryRow(ctx, `
			INSERT INTO stocktakes (warehouse_id, scope_kind, created_by)
			VALUES ($1::uuid, $2, $3::uuid)
			RETURNING id::text, number`, in.WarehouseID, in.ScopeKind, in.CreatedBy).
			Scan(&out.ID, &out.Number); err != nil {
			return stocktakeRefErr(err, "завести пересчёт")
		}
		if col, ok := stocktakeScopeColumn[in.ScopeKind]; ok {
			if _, err := q.Exec(ctx, `
				INSERT INTO stocktake_scope (stocktake_id, `+col+`)
				SELECT $1::uuid, unnest($2::text[]::uuid[])`, out.ID, in.ObjectIDs); err != nil {
				return stocktakeRefErr(err, "область пересчёта")
			}
		}
		if in.ScopeKind == model.StocktakeScopeCells {
			if err := guardStocktakeCells(ctx, q, in.WarehouseID, in.ObjectIDs); err != nil {
				return err
			}
		}

		tag, err := q.Exec(ctx, `
			INSERT INTO stocktake_cells (stocktake_id, cell_id)
			SELECT $1::uuid, c.id FROM cells c
			WHERE c.warehouse_id = $2::uuid AND NOT c.is_default AND `+where+`
			ORDER BY c.address`, out.ID, in.WarehouseID)
		if err != nil {
			return fmt.Errorf("ячейки пересчёта: %w", err)
		}
		if out.Cells = int(tag.RowsAffected()); out.Cells == 0 {
			return model.ErrStocktakeNoCells
		}

		if err := q.QueryRow(ctx, `
			INSERT INTO warehouse_tasks (kind, warehouse_id, stocktake_id)
			VALUES ($1, $2::uuid, $3::uuid)
			RETURNING id::text`, model.TaskStocktake, in.WarehouseID, out.ID).Scan(&out.TaskID); err != nil {
			return fmt.Errorf("задание на пересчёт: %w", err)
		}
		return addTaskEvent(ctx, q, out.TaskID, model.TaskEventCreated, in.CreatedBy, "", "")
	})
	if err != nil {
		return model.StocktakeCreated{}, err
	}
	return out, nil
}

// guardStocktakeCells — выбранные ячейки есть на складе пересчёта, и среди них нет ячейки
// приёмки. Существование уже проверил внешний ключ области; здесь — склад и приёмка.
func guardStocktakeCells(ctx context.Context, q Querier, warehouseID string, ids []string) error {
	var foreign int
	var receiving bool
	if err := q.QueryRow(ctx, `
		SELECT count(*) FILTER (WHERE warehouse_id <> $2::uuid), COALESCE(bool_or(is_default), false)
		FROM cells WHERE id = ANY($1::text[]::uuid[])`, ids, warehouseID).Scan(&foreign, &receiving); err != nil {
		return fmt.Errorf("проверить ячейки пересчёта: %w", err)
	}
	if foreign > 0 {
		return model.ErrStocktakeUnknownObject
	}
	if receiving {
		return model.ErrStocktakeReceivingCell
	}
	return nil
}

// stocktakeRefErr — нарушение внешнего ключа (нет склада, автора или объекта области) —
// ErrStocktakeUnknownObject; остальное — сбой.
func stocktakeRefErr(err error, what string) error {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23503" {
		return model.ErrStocktakeUnknownObject
	}
	return fmt.Errorf("%s: %w", what, err)
}

// stocktakeLockKey — пространство рекомендательных блокировок ячеек пересчёта; движение берёт
// ту же блокировку разделяемой (миграция 31, `stocktake_disrupt_cells`).
const stocktakeLockKey = 1010

// StartCount начинает подсчёт ячейки: снимает «ожидалось» и ставит её на пересчёт (P10-02).
//
// Что: строки ячейки пересчёта — россыпь (товар · партия · склад), живые короба целиком
// (ожидается 1) и марки ЧЗ россыпью; ячейка `counting` — с этого момента движение через неё
// сбивает подсчёт (триггеры миграции 31).
// Зачем: снимок в момент скана ячейки на месте, а не при заведении пересчёта: между ними могут
// пройти часы, и снимок разошёлся бы с полкой.
// Как: подсчёт начинает тот, кто держит ячейку, — взятую (`taken`) или сбитую (`disrupted`,
// тогда прежние строки заменяются). Повтор по уже начатой своей ячейке снимка не трогает —
// возвращает снятое: повтор операции не должен стирать подсчитанное. Перед чтением берётся
// исключительная блокировка ячейки: идущие движения дописываются в снимок, начатые после —
// ждут его фиксации и помечают подсчёт сбитым. Россыпь и короба — теми же расчётами, что
// «Остатки» (looseStock, liveLoadUnits): снимок не расходится с тем, что видит кладовщик.
// При области по группе, поставщику, товару снимается только товар области, а короб — если в
// нём есть товар области.
func (r *StocktakeRepository) StartCount(ctx context.Context, stocktakeCellID, userID string) (model.StocktakeCellSnapshot, error) {
	var out model.StocktakeCellSnapshot
	err := WithinTx(ctx, r.pool, func(q Querier) error {
		var cellID string
		err := q.QueryRow(ctx, `SELECT cell_id::text FROM stocktake_cells WHERE id = $1::uuid`, stocktakeCellID).
			Scan(&cellID)
		if errors.Is(err, pgx.ErrNoRows) {
			return model.ErrStocktakeCellNotFound
		}
		if err != nil {
			return fmt.Errorf("ячейка пересчёта: %w", err)
		}
		if _, err := q.Exec(ctx, `SELECT pg_advisory_xact_lock($1, hashtext($2))`, stocktakeLockKey, cellID); err != nil {
			return fmt.Errorf("заблокировать ячейку пересчёта: %w", err)
		}

		var stocktakeID, status, stocktakeStatus, scopeKind string
		var takenBy *string
		if err := q.QueryRow(ctx, `
			SELECT st.id::text, sc.status, sc.taken_by::text, st.status, st.scope_kind
			FROM stocktake_cells sc
			JOIN stocktakes st ON st.id = sc.stocktake_id
			WHERE sc.id = $1::uuid
			FOR UPDATE OF sc`, stocktakeCellID).
			Scan(&stocktakeID, &status, &takenBy, &stocktakeStatus, &scopeKind); err != nil {
			return fmt.Errorf("ячейка пересчёта: %w", err)
		}
		if stocktakeStatus == "closed" {
			return model.ErrStocktakeClosed
		}
		if takenBy == nil || *takenBy != userID {
			return model.ErrStocktakeCellNotYours
		}
		switch status {
		case model.StocktakeCellCounting:
			out, err = stocktakeSnapshotSize(ctx, q, stocktakeCellID)
			return err
		case model.StocktakeCellTaken, model.StocktakeCellDisrupted:
		default:
			return model.ErrStocktakeCellNotYours
		}

		if _, err := q.Exec(ctx, `DELETE FROM stocktake_lines WHERE stocktake_cell_id = $1::uuid`,
			stocktakeCellID); err != nil {
			return fmt.Errorf("сбросить прежний подсчёт: %w", err)
		}
		snap := stocktakeSnapshot{q: q, stCell: stocktakeCellID, cell: cellID, lines: map[stocktakeLineKey]string{}}
		if model.StocktakeCountsAreaGoodsOnly(scopeKind) {
			if snap.area, err = stocktakeAreaGoodsInCell(ctx, q, stocktakeID, cellID); err != nil {
				return err
			}
		}
		if out, err = snap.take(ctx); err != nil {
			return err
		}

		if _, err := q.Exec(ctx, `
			UPDATE stocktake_cells SET status = 'counting', started_at = now()
			WHERE id = $1::uuid`, stocktakeCellID); err != nil {
			return fmt.Errorf("начать подсчёт ячейки: %w", err)
		}
		if _, err := q.Exec(ctx, `
			UPDATE stocktakes SET status = 'in_progress' WHERE id = $1::uuid AND status = 'new'`,
			stocktakeID); err != nil {
			return fmt.Errorf("пересчёт в работе: %w", err)
		}
		return nil
	})
	if err != nil {
		return model.StocktakeCellSnapshot{}, err
	}
	return out, nil
}

// stocktakeAreaGoodsInCell — товары области пересчёта, лежащие в ячейке (россыпью или в
// коробах: остаток ячейки включает короба).
func stocktakeAreaGoodsInCell(ctx context.Context, q Querier, stocktakeID, cellID string) (map[string]bool, error) {
	rows, err := q.Query(ctx, `
		SELECT DISTINCT s.good_id::text FROM stock s
		WHERE s.cell_id = $2::uuid AND s.good_id IN (`+stocktakeAreaGoodsSQL+`)`, stocktakeID, cellID)
	if err != nil {
		return nil, fmt.Errorf("товары области в ячейке: %w", err)
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return nil, fmt.Errorf("товары области в ячейке: %w", err)
	}
	out := make(map[string]bool, len(ids))
	for _, id := range ids {
		out[id] = true
	}
	return out, nil
}

// stocktakeSnapshotSize — сколько строк и марок уже снято по ячейке пересчёта.
func stocktakeSnapshotSize(ctx context.Context, q Querier, stocktakeCellID string) (model.StocktakeCellSnapshot, error) {
	var out model.StocktakeCellSnapshot
	if err := q.QueryRow(ctx, `
		SELECT (SELECT count(*) FROM stocktake_lines WHERE stocktake_cell_id = $1::uuid),
		       (SELECT count(*) FROM stocktake_marks WHERE stocktake_cell_id = $1::uuid)`, stocktakeCellID).
		Scan(&out.Lines, &out.Marks); err != nil {
		return out, fmt.Errorf("снимок ячейки пересчёта: %w", err)
	}
	return out, nil
}

// stocktakeLineKey — позиция россыпи в снимке: товар · партия · внутренний склад.
type stocktakeLineKey struct{ good, batch, iwh string }

// stocktakeSnapshot — снятие «ожидалось» по одной ячейке пересчёта. area — товары области; nil —
// ячейка считается целиком.
type stocktakeSnapshot struct {
	q      Querier
	stCell string
	cell   string
	area   map[string]bool
	lines  map[stocktakeLineKey]string
}

// inArea — товар считается этим пересчётом.
func (s *stocktakeSnapshot) inArea(goodID string) bool {
	return s.area == nil || s.area[goodID]
}

// take пишет строки россыпи, коробов и марки ячейки.
func (s *stocktakeSnapshot) take(ctx context.Context) (model.StocktakeCellSnapshot, error) {
	var out model.StocktakeCellSnapshot
	loose, err := looseStock(ctx, s.q, &s.cell)
	if err != nil {
		return out, err
	}
	for _, ln := range loose {
		if !s.inArea(ln.GoodID) {
			continue
		}
		if _, err := s.looseLine(ctx, stocktakeLineKey{ln.GoodID, ln.BatchID, ln.InternalWarehouseID},
			ln.Qty.String()); err != nil {
			return out, err
		}
	}

	boxes, err := liveLoadUnits(ctx, s.q, &s.cell)
	if err != nil {
		return out, err
	}
	for _, lu := range boxes {
		if !s.boxInArea(lu) {
			continue
		}
		if _, err := s.q.Exec(ctx, `
			INSERT INTO stocktake_lines (stocktake_cell_id, load_unit_id, internal_warehouse_id, expected_qty)
			VALUES ($1::uuid, $2::uuid, $3::uuid, 1)`, s.stCell, lu.ID, lu.InternalWarehouseID); err != nil {
			return out, fmt.Errorf("строка короба в снимке: %w", err)
		}
		out.Lines++
	}

	if out.Marks, err = s.marks(ctx); err != nil {
		return out, err
	}
	out.Lines += len(s.lines)
	return out, nil
}

// boxInArea — короб считается: ячейка целиком или в коробе есть товар области.
func (s *stocktakeSnapshot) boxInArea(lu model.LoadUnitCard) bool {
	if s.area == nil {
		return true
	}
	for _, c := range lu.Contents {
		if s.area[c.GoodID] {
			return true
		}
	}
	return false
}

// looseLine — строка россыпи позиции: заводит её с ожидаемым количеством или возвращает уже
// заведённую.
func (s *stocktakeSnapshot) looseLine(ctx context.Context, key stocktakeLineKey, expected string) (string, error) {
	if id, ok := s.lines[key]; ok {
		return id, nil
	}
	var id string
	if err := s.q.QueryRow(ctx, `
		INSERT INTO stocktake_lines (stocktake_cell_id, good_id, batch_id, internal_warehouse_id, expected_qty)
		VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, $5::numeric)
		RETURNING id::text`, s.stCell, key.good, key.batch, key.iwh, expected).Scan(&id); err != nil {
		return "", fmt.Errorf("строка россыпи в снимке: %w", err)
	}
	s.lines[key] = id
	return id, nil
}

// marks — марки ЧЗ россыпью в ячейке: каждая «ожидалась» на строке своей позиции. Марка без
// остатка россыпью (учёт разошёлся) заводит строку с нулём — она всё равно ожидается на полке.
func (s *stocktakeSnapshot) marks(ctx context.Context) (int, error) {
	rows, err := s.q.Query(ctx, `
		SELECT cis, good_id::text, batch_id::text, internal_warehouse_id::text
		FROM cz_marks
		WHERE status = $1 AND cell_id = $2::uuid
		ORDER BY cis`, model.CZMarkInStock, s.cell)
	if err != nil {
		return 0, fmt.Errorf("марки ячейки: %w", err)
	}
	type mark struct {
		cis string
		key stocktakeLineKey
	}
	var marks []mark
	for rows.Next() {
		var m mark
		if err := rows.Scan(&m.cis, &m.key.good, &m.key.batch, &m.key.iwh); err != nil {
			rows.Close()
			return 0, fmt.Errorf("разобрать марку ячейки: %w", err)
		}
		marks = append(marks, m)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, fmt.Errorf("марки ячейки: %w", err)
	}

	n := 0
	for _, m := range marks {
		if !s.inArea(m.key.good) {
			continue
		}
		line, err := s.looseLine(ctx, m.key, "0")
		if err != nil {
			return 0, err
		}
		if _, err := s.q.Exec(ctx, `
			INSERT INTO stocktake_marks (stocktake_cell_id, cis, line_id, expected)
			VALUES ($1::uuid, $2, $3::uuid, true)`, s.stCell, m.cis, line); err != nil {
			return 0, fmt.Errorf("марка в снимке: %w", err)
		}
		n++
	}
	return n, nil
}
