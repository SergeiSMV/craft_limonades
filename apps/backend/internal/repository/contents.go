package repository

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/model"
)

// ContentsRepository — что лежит в ячейках и коробах: карточка короба, содержимое ячейки
// и снимок для кэша ТСД (P5-05). Только чтение.
type ContentsRepository struct {
	pool *pgxpool.Pool
}

// NewContentsRepository создаёт репозиторий просмотра содержимого.
func NewContentsRepository(pool *pgxpool.Pool) *ContentsRepository {
	return &ContentsRepository{pool: pool}
}

// withinSnapshot выполняет чтения в одной транзакции REPEATABLE READ только на чтение.
//
// Зачем: короба, их содержимое и россыпь читаются разными запросами. В READ COMMITTED
// каждый запрос видит свой момент, и размещение, проведённое между ними, показало бы короб
// в двух ячейках или ни в одной, а россыпь — без вычета переехавшего короба. REPEATABLE READ
// даёт всем запросам один снимок базы.
func (r *ContentsRepository) withinSnapshot(ctx context.Context, fn func(Querier) error) error {
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return fmt.Errorf("begin snapshot tx: %w", err)
	}
	// Транзакция только читает: откат и фиксация равнозначны, откат не оставляет следов.
	defer func() { _ = tx.Rollback(ctx) }()
	return fn(tx)
}

// Snapshot возвращает все живые короба с содержимым и всю россыпь склада одним согласованным
// снимком — для кэша ТСД.
//
// Ответ целиком, без страниц: постраничная загрузка шла бы разными транзакциями, и короб,
// переехавший между страницами, попал бы в снимок дважды или пропал. На масштабе пилота это
// сотни коробов; рост — риск масштабирования (dev-context §10), лечится дельтой по updated_at.
func (r *ContentsRepository) Snapshot(ctx context.Context) (model.ContentsSnapshot, error) {
	var snap model.ContentsSnapshot
	err := r.withinSnapshot(ctx, func(q Querier) error {
		// now() в транзакции — момент её начала: именно на него согласован снимок.
		if err := q.QueryRow(ctx, `SELECT now()`).Scan(&snap.AsOf); err != nil {
			return fmt.Errorf("момент снимка: %w", err)
		}
		var err error
		if snap.LoadUnits, err = liveLoadUnits(ctx, q, nil); err != nil {
			return err
		}
		snap.Loose, err = looseStock(ctx, q, nil)
		return err
	})
	if err != nil {
		return model.ContentsSnapshot{}, err
	}
	return snap, nil
}

// CellContents возвращает живые короба и россыпь одной ячейки или model.ErrCellNotFound.
func (r *ContentsRepository) CellContents(ctx context.Context, cellID string) (model.CellContents, error) {
	out := model.CellContents{CellID: cellID}
	err := r.withinSnapshot(ctx, func(q Querier) error {
		err := q.QueryRow(ctx, `SELECT address, warehouse_id::text FROM cells WHERE id = $1::uuid`, cellID).
			Scan(&out.Address, &out.WarehouseID)
		if errors.Is(err, pgx.ErrNoRows) {
			return model.ErrCellNotFound
		}
		if err != nil {
			return fmt.Errorf("прочитать ячейку: %w", err)
		}
		if out.LoadUnits, err = liveLoadUnits(ctx, q, &cellID); err != nil {
			return err
		}
		out.Loose, err = looseStock(ctx, q, &cellID)
		return err
	})
	if err != nil {
		return model.CellContents{}, err
	}
	return out, nil
}

// LoadUnitCard возвращает карточку короба — в том числе неживого (не размещён или пуст):
// кладовщику надо сказать, что с отсканированным коробом, а не что его нет.
// Нет такого короба — model.ErrLoadUnitNotFound.
func (r *ContentsRepository) LoadUnitCard(ctx context.Context, id string) (model.LoadUnitCard, error) {
	var card model.LoadUnitCard
	err := r.withinSnapshot(ctx, func(q Querier) error {
		err := q.QueryRow(ctx, `
			SELECT lu.id::text, lu.kind, lu.status, lu.cell_id::text, c.address, lu.created_at
			FROM load_units lu
			LEFT JOIN cells c ON c.id = lu.cell_id
			WHERE lu.id = $1::uuid`, id).
			Scan(&card.ID, &card.Kind, &card.Status, &card.CellID, &card.CellAddress, &card.CreatedAt)
		if errors.Is(err, pgx.ErrNoRows) {
			return model.ErrLoadUnitNotFound
		}
		if err != nil {
			return fmt.Errorf("прочитать короб: %w", err)
		}
		contents, err := loadUnitLines(ctx, q, []string{id})
		if err != nil {
			return err
		}
		card.Contents = contents[id]
		card.Live = card.CellID != nil && len(card.Contents) > 0
		return nil
	})
	if err != nil {
		return model.LoadUnitCard{}, err
	}
	return card, nil
}

// liveLoadUnits — живые короба (размещены и не пусты) с содержимым; cellID — фильтр по
// ячейке, nil — весь склад.
//
// Вложенность ГЕ не разворачивается: в пилоте её нет (паллетная логика вне объёма), и короб
// показывается со своим содержимым. Тот же фильтр «qty > 0» применяют задания и размещение.
func liveLoadUnits(ctx context.Context, q Querier, cellID *string) ([]model.LoadUnitCard, error) {
	rows, err := q.Query(ctx, `
		SELECT lu.id::text, lu.kind, lu.status, lu.cell_id::text, c.address, lu.created_at
		FROM load_units lu
		JOIN cells c ON c.id = lu.cell_id
		WHERE ($1::uuid IS NULL OR lu.cell_id = $1::uuid)
		  AND EXISTS (SELECT 1 FROM lu_content x WHERE x.load_unit_id = lu.id AND x.qty > 0)
		ORDER BY c.address, lu.created_at, lu.id`, cellID)
	if err != nil {
		return nil, fmt.Errorf("живые короба: %w", err)
	}
	defer rows.Close()

	var out []model.LoadUnitCard
	var ids []string
	for rows.Next() {
		var lu model.LoadUnitCard
		if err := rows.Scan(&lu.ID, &lu.Kind, &lu.Status, &lu.CellID, &lu.CellAddress, &lu.CreatedAt); err != nil {
			return nil, fmt.Errorf("разобрать короб: %w", err)
		}
		lu.Live = true
		out = append(out, lu)
		ids = append(ids, lu.ID)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	contents, err := loadUnitLines(ctx, q, ids)
	if err != nil {
		return nil, err
	}
	for i := range out {
		out[i].Contents = contents[out[i].ID]
	}
	return out, nil
}

// loadUnitLines — содержимое коробов с товаром и партией, только строки с количеством.
func loadUnitLines(ctx context.Context, q Querier, ids []string) (map[string][]model.ContentLine, error) {
	out := make(map[string][]model.ContentLine, len(ids))
	if len(ids) == 0 {
		return out, nil
	}
	rows, err := q.Query(ctx, `
		SELECT c.load_unit_id::text, g.id::text, g.code, g.name, g.uom,
		       b.id::text, b.production_date, c.qty::text
		FROM lu_content c
		JOIN goods g   ON g.id = c.good_id
		JOIN batches b ON b.id = c.batch_id
		WHERE c.load_unit_id = ANY($1::text[]::uuid[]) AND c.qty > 0
		ORDER BY c.load_unit_id, g.name, b.production_date`, ids)
	if err != nil {
		return nil, fmt.Errorf("содержимое коробов: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var lu string
		var ln model.ContentLine
		if err := scanContentLine(rows, &lu, &ln); err != nil {
			return nil, fmt.Errorf("разобрать содержимое короба: %w", err)
		}
		out[lu] = append(out[lu], ln)
	}
	return out, rows.Err()
}

// looseStock — россыпь по ячейкам; cellID — фильтр по ячейке, nil — весь склад.
//
// Россыпь = остаток ячейки минус содержимое лежащих в ней коробов, по товару и партии —
// то же правило, что у размещения россыпи (putawayLoose); согласие двух расчётов проверяет
// тест. Строки без россыпи (всё в коробах) отбрасываются.
//
// ⚠ Содержимое короба не знает внутреннего склада, и вычет идёт из строки остатка любого
// внутреннего склада — как и в putawayLoose. Верно, пока приёмка кладёт всё в склад по
// умолчанию (ADR-0016, P4-01-1); перевод в «Брак» (P6-07) должен будет это учесть.
func looseStock(ctx context.Context, q Querier, cellID *string) ([]model.LooseLine, error) {
	rows, err := q.Query(ctx, `
		WITH boxed AS (
			SELECT lu.cell_id, c.good_id, c.batch_id, sum(c.qty) AS qty
			FROM lu_content c
			JOIN load_units lu ON lu.id = c.load_unit_id
			WHERE lu.cell_id IS NOT NULL
			  AND ($1::uuid IS NULL OR lu.cell_id = $1::uuid)
			GROUP BY lu.cell_id, c.good_id, c.batch_id
		)
		SELECT s.cell_id::text, s.internal_warehouse_id::text,
		       g.id::text, g.code, g.name, g.uom,
		       b.id::text, b.production_date, (s.qty - COALESCE(bx.qty, 0))::text
		FROM stock s
		JOIN goods g   ON g.id = s.good_id
		JOIN batches b ON b.id = s.batch_id
		JOIN cells c   ON c.id = s.cell_id
		LEFT JOIN boxed bx ON bx.cell_id = s.cell_id AND bx.good_id = s.good_id AND bx.batch_id = s.batch_id
		WHERE ($1::uuid IS NULL OR s.cell_id = $1::uuid)
		  AND s.qty - COALESCE(bx.qty, 0) > 0
		ORDER BY c.address, g.name, b.production_date`, cellID)
	if err != nil {
		return nil, fmt.Errorf("россыпь по ячейкам: %w", err)
	}
	defer rows.Close()

	var out []model.LooseLine
	for rows.Next() {
		var ln model.LooseLine
		var code *string
		var qty string
		if err := rows.Scan(&ln.CellID, &ln.InternalWarehouseID,
			&ln.GoodID, &code, &ln.GoodName, &ln.Uom, &ln.BatchID, &ln.ProductionDate, &qty); err != nil {
			return nil, fmt.Errorf("разобрать россыпь: %w", err)
		}
		ln.GoodCode = deref(code)
		if ln.Qty, err = parseQty(qty); err != nil {
			return nil, err
		}
		out = append(out, ln)
	}
	return out, rows.Err()
}

// scanContentLine разбирает строку «короб, товар, партия, количество».
func scanContentLine(rows pgx.Rows, lu *string, ln *model.ContentLine) error {
	var code *string
	var qty string
	if err := rows.Scan(lu, &ln.GoodID, &code, &ln.GoodName, &ln.Uom, &ln.BatchID, &ln.ProductionDate, &qty); err != nil {
		return err
	}
	ln.GoodCode = deref(code)
	q, err := parseQty(qty)
	if err != nil {
		return err
	}
	ln.Qty = q
	return nil
}
