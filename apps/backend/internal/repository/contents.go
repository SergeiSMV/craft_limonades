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

// SearchLoadUnits ищет короба по короткому коду с ярлыка — вхождению [code] в последние восемь
// знаков идентификатора (P5-05-1). [code] уже приведён: шестнадцатеричные знаки, заглавными.
//
// Ищутся ВСЕ короба, живые и нет: ярлык перепечатывают как раз тогда, когда короб «пропал» —
// он пуст, не размещён или появился после снимка на терминале. Живость отдаётся признаком.
// Сначала живые, затем по адресу ячейки и времени создания; [limit] — защита от выдачи на весь
// склад по одному знаку.
//
// Без индекса: выражение по хвосту id просматривает все короба. На масштабе пилота — сотни
// строк; рост — индекс по тому же выражению хвоста id.
func (r *ContentsRepository) SearchLoadUnits(ctx context.Context, code string, limit int) ([]model.LoadUnitCard, error) {
	var out []model.LoadUnitCard
	err := r.withinSnapshot(ctx, func(q Querier) error {
		rows, err := q.Query(ctx, `
			SELECT lu.id::text, lu.kind, lu.status, lu.cell_id::text, c.address, lu.created_at
			FROM load_units lu
			LEFT JOIN cells c ON c.id = lu.cell_id
			WHERE strpos(upper(right(replace(lu.id::text, '-', ''), 8)), $1) > 0
			ORDER BY (lu.cell_id IS NOT NULL
			          AND EXISTS (SELECT 1 FROM lu_content x WHERE x.load_unit_id = lu.id AND x.qty > 0)) DESC,
			         c.address NULLS LAST, lu.created_at, lu.id
			LIMIT $2`, code, limit)
		if err != nil {
			return fmt.Errorf("поиск коробов по коду: %w", err)
		}
		defer rows.Close()
		var ids []string
		for rows.Next() {
			var lu model.LoadUnitCard
			if err := rows.Scan(&lu.ID, &lu.Kind, &lu.Status, &lu.CellID, &lu.CellAddress, &lu.CreatedAt); err != nil {
				return fmt.Errorf("разобрать короб: %w", err)
			}
			out = append(out, lu)
			ids = append(ids, lu.ID)
		}
		if err := rows.Err(); err != nil {
			return err
		}
		contents, err := loadUnitLines(ctx, q, ids)
		if err != nil {
			return err
		}
		for i := range out {
			out[i].Contents = contents[out[i].ID]
			out[i].Live = out[i].CellID != nil && len(out[i].Contents) > 0
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

// LoadUnitHistory возвращает историю короба: приёмку, которая его завела, и переносы из журнала
// размещений по порядку — с адресами и ФИО (P5-05-1). Нет короба — model.ErrLoadUnitNotFound.
func (r *ContentsRepository) LoadUnitHistory(ctx context.Context, id string) (model.LoadUnitHistory, error) {
	h := model.LoadUnitHistory{LoadUnitID: id, Moves: []model.LoadUnitMove{}}
	err := r.withinSnapshot(ctx, func(q Querier) error {
		err := q.QueryRow(ctx, `SELECT created_at FROM load_units WHERE id = $1::uuid`, id).Scan(&h.CreatedAt)
		if errors.Is(err, pgx.ErrNoRows) {
			return model.ErrLoadUnitNotFound
		}
		if err != nil {
			return fmt.Errorf("прочитать короб: %w", err)
		}

		// Короб заводит его приёмка (P4-09): строка приёмки ссылается на него. Строк с этим
		// коробом в документе может быть несколько — документ один.
		var rc model.LoadUnitReceipt
		err = q.QueryRow(ctx, `
			SELECT r.id::text, u.full_name, s.name, r.posted_at
			FROM receipt_lines rl
			JOIN receipts r       ON r.id = rl.receipt_id
			JOIN users u          ON u.id = r.created_by
			LEFT JOIN suppliers s ON s.id = r.supplier_id
			WHERE rl.load_unit_id = $1::uuid
			ORDER BY r.created_at
			LIMIT 1`, id).Scan(&rc.ReceiptID, &rc.ReceivedBy, &rc.SupplierName, &rc.PostedAt)
		switch {
		case errors.Is(err, pgx.ErrNoRows):
		case err != nil:
			return fmt.Errorf("приёмка короба: %w", err)
		default:
			h.Receipt = &rc
		}

		rows, err := q.Query(ctx, `
			SELECT cf.address, ct.address, p.source, u.full_name, p.placed_at
			FROM placements p
			LEFT JOIN cells cf ON cf.id = p.from_cell_id
			JOIN cells ct      ON ct.id = p.to_cell_id
			LEFT JOIN users u  ON u.id = p.user_id
			WHERE p.load_unit_id = $1::uuid
			ORDER BY p.placed_at, p.id`, id)
		if err != nil {
			return fmt.Errorf("переносы короба: %w", err)
		}
		defer rows.Close()
		for rows.Next() {
			var m model.LoadUnitMove
			if err := rows.Scan(&m.FromAddress, &m.ToAddress, &m.Source, &m.UserName, &m.At); err != nil {
				return fmt.Errorf("разобрать перенос: %w", err)
			}
			h.Moves = append(h.Moves, m)
		}
		return rows.Err()
	})
	if err != nil {
		return model.LoadUnitHistory{}, err
	}
	return h, nil
}
