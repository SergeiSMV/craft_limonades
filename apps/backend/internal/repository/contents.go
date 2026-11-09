package repository

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/shopspring/decimal"

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

// czBoxColumns — код короба ЧЗ и признак вскрытия для карточки ГЕ (CZ-06). Запрос обязан
// присоединить `cz_aggregates cza ON cza.load_unit_id = lu.id` (LEFT JOIN): у своего короба
// с QR агрегата нет, код — NULL, вскрытия нет.
const czBoxColumns = `cza.code, cza.opened_at IS NOT NULL`

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
		if snap.Loose, err = looseStock(ctx, q, nil); err != nil {
			return err
		}
		snap.Marks, err = marksInStock(ctx, q)
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
			SELECT lu.id::text, lu.kind, lu.status, lu.cell_id::text, c.address, lu.created_at,
			       lu.internal_warehouse_id::text, `+czBoxColumns+`
			FROM load_units lu
			LEFT JOIN cells c ON c.id = lu.cell_id
			LEFT JOIN cz_aggregates cza ON cza.load_unit_id = lu.id
			WHERE lu.id = $1::uuid`, id).
			Scan(&card.ID, &card.Kind, &card.Status, &card.CellID, &card.CellAddress, &card.CreatedAt,
				&card.InternalWarehouseID, &card.CZCode, &card.CZOpened)
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

// LoadUnitByCZCode — карточка ГЕ короба ЧЗ по коду `00`+SSCC (CZ-06). Нет такого принятого
// короба — model.ErrLoadUnitNotFound.
func (r *ContentsRepository) LoadUnitByCZCode(ctx context.Context, code string) (model.LoadUnitCard, error) {
	var id string
	err := r.pool.QueryRow(ctx, `
		SELECT load_unit_id::text FROM cz_aggregates
		WHERE code = $1 AND kind = $2 AND load_unit_id IS NOT NULL`, code, model.CZAggregateBox).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return model.LoadUnitCard{}, model.ErrLoadUnitNotFound
	}
	if err != nil {
		return model.LoadUnitCard{}, fmt.Errorf("короб ЧЗ по коду: %w", err)
	}
	return r.LoadUnitCard(ctx, id)
}

// liveLoadUnits — живые короба (размещены и не пусты) с содержимым; cellID — фильтр по
// ячейке, nil — весь склад.
//
// Вложенность ГЕ не разворачивается: в пилоте её нет (паллетная логика вне объёма), и короб
// показывается со своим содержимым. Тот же фильтр «qty > 0» применяют задания и размещение.
func liveLoadUnits(ctx context.Context, q Querier, cellID *string) ([]model.LoadUnitCard, error) {
	rows, err := q.Query(ctx, `
		SELECT lu.id::text, lu.kind, lu.status, lu.cell_id::text, c.address, lu.created_at,
			       lu.internal_warehouse_id::text, `+czBoxColumns+`
		FROM load_units lu
		JOIN cells c ON c.id = lu.cell_id
		LEFT JOIN cz_aggregates cza ON cza.load_unit_id = lu.id
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
		if err := rows.Scan(&lu.ID, &lu.Kind, &lu.Status, &lu.CellID, &lu.CellAddress, &lu.CreatedAt,
			&lu.InternalWarehouseID, &lu.CZCode, &lu.CZOpened); err != nil {
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
// Короб принадлежит внутреннему складу целиком (P6-07-1), поэтому вычет идёт из строки
// остатка склада короба: россыпь «Брака» — остаток «Брака» минус короба «Брака».
func looseStock(ctx context.Context, q Querier, cellID *string) ([]model.LooseLine, error) {
	rows, err := q.Query(ctx, `
		WITH boxed AS (
			SELECT lu.cell_id, lu.internal_warehouse_id, c.good_id, c.batch_id, sum(c.qty) AS qty
			FROM lu_content c
			JOIN load_units lu ON lu.id = c.load_unit_id
			WHERE lu.cell_id IS NOT NULL
			  AND ($1::uuid IS NULL OR lu.cell_id = $1::uuid)
			GROUP BY lu.cell_id, lu.internal_warehouse_id, c.good_id, c.batch_id
		),
		-- «В сборке» россыпью (P9-05): открытые пики без короба-источника.
		in_picking AS (
			SELECT source_cell_id AS cell_id, internal_warehouse_id, good_id, batch_id, sum(qty) AS qty
			FROM picking_picks
			WHERE state = 'picking' AND source_load_unit_id IS NULL
			  AND ($1::uuid IS NULL OR source_cell_id = $1::uuid)
			GROUP BY source_cell_id, internal_warehouse_id, good_id, batch_id
		)
		SELECT s.cell_id::text, s.internal_warehouse_id::text,
		       g.id::text, g.code, g.name, g.uom,
		       b.id::text, b.production_date, (s.qty - COALESCE(bx.qty, 0))::text,
		       COALESCE(ip.qty, 0)::text
		FROM stock s
		JOIN goods g   ON g.id = s.good_id
		JOIN batches b ON b.id = s.batch_id
		JOIN cells c   ON c.id = s.cell_id
		LEFT JOIN boxed bx ON bx.cell_id = s.cell_id AND bx.good_id = s.good_id AND bx.batch_id = s.batch_id
		                  AND bx.internal_warehouse_id = s.internal_warehouse_id
		LEFT JOIN in_picking ip ON ip.cell_id = s.cell_id AND ip.good_id = s.good_id AND ip.batch_id = s.batch_id
		                       AND ip.internal_warehouse_id = s.internal_warehouse_id
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
		var qty, inPicking string
		if err := rows.Scan(&ln.CellID, &ln.InternalWarehouseID,
			&ln.GoodID, &code, &ln.GoodName, &ln.Uom, &ln.BatchID, &ln.ProductionDate, &qty, &inPicking); err != nil {
			return nil, fmt.Errorf("разобрать россыпь: %w", err)
		}
		ln.GoodCode = deref(code)
		if ln.Qty, err = parseQty(qty); err != nil {
			return nil, err
		}
		if ln.InPicking, err = parseQty(inPicking); err != nil {
			return nil, err
		}
		out = append(out, ln)
	}
	return out, rows.Err()
}

// marksInStock — все марки ЧЗ, числящиеся на складе (CZ-06), для снимка ТСД.
//
// Только `in_stock`: ушедшая марка места не имеет, и терминалу её искать незачем. Партия —
// с датой выпуска: операции ТСД несут партию датой.
func marksInStock(ctx context.Context, q Querier) ([]model.ContentsMark, error) {
	rows, err := q.Query(ctx, `
		SELECT m.cis, m.good_id::text, m.batch_id::text, b.production_date,
		       m.load_unit_id::text, m.cell_id::text, m.internal_warehouse_id::text, m.aggregate_code
		FROM cz_marks m
		JOIN batches b ON b.id = m.batch_id
		WHERE m.status = $1
		ORDER BY m.cis`, model.CZMarkInStock)
	if err != nil {
		return nil, fmt.Errorf("марки на складе: %w", err)
	}
	defer rows.Close()
	var out []model.ContentsMark
	for rows.Next() {
		var m model.ContentsMark
		if err := rows.Scan(&m.CIS, &m.GoodID, &m.BatchID, &m.ProductionDate,
			&m.LoadUnitID, &m.CellID, &m.InternalWarehouseID, &m.AggregateCode); err != nil {
			return nil, fmt.Errorf("разобрать марку: %w", err)
		}
		out = append(out, m)
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
			SELECT lu.id::text, lu.kind, lu.status, lu.cell_id::text, c.address, lu.created_at,
			       lu.internal_warehouse_id::text, `+czBoxColumns+`
			FROM load_units lu
			LEFT JOIN cells c ON c.id = lu.cell_id
			LEFT JOIN cz_aggregates cza ON cza.load_unit_id = lu.id
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
			if err := rows.Scan(&lu.ID, &lu.Kind, &lu.Status, &lu.CellID, &lu.CellAddress, &lu.CreatedAt,
				&lu.InternalWarehouseID, &lu.CZCode, &lu.CZOpened); err != nil {
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
// loadUnitContentEvents — изменения состава короба из всех журналов, по времени (ADHOC-32):
// строки движения в короб и из него, вынимание части короба при пометке проблемы, списание
// и отгрузка возврата его содержимого. Одним запросом — порядок задаёт база.
func loadUnitContentEvents(ctx context.Context, q Querier, id string) ([]model.LoadUnitContentEvent, error) {
	rows, err := q.Query(ctx, `
		SELECT e.kind, g.name, g.uom, b.production_date, e.qty::text, e.peer, e.peer_lu::text,
		       u.full_name, e.at
		FROM (
			SELECT 'in' AS kind, l.good_id, l.batch_id, l.qty, cf.address AS peer,
			       l.from_load_unit_id AS peer_lu, m.created_by AS user_id, m.posted_at AS at, l.line_no AS ord
			FROM movement_lines l JOIN movements m ON m.id = l.movement_id
			JOIN cells cf ON cf.id = l.from_cell_id
			WHERE l.to_load_unit_id = $1::uuid AND l.good_id IS NOT NULL
			UNION ALL
			SELECT 'out', l.good_id, l.batch_id, l.qty, ct.address, l.to_load_unit_id,
			       m.created_by, m.posted_at, l.line_no
			FROM movement_lines l JOIN movements m ON m.id = l.movement_id
			JOIN cells ct ON ct.id = l.to_cell_id
			WHERE l.from_load_unit_id = $1::uuid AND l.good_id IS NOT NULL
			UNION ALL
			SELECT 'problem', p.good_id, p.batch_id, p.qty, c.address, NULL,
			       p.created_by, p.created_at, 0
			FROM warehouse_problems p JOIN cells c ON c.id = p.cell_id
			WHERE p.from_load_unit_id = $1::uuid
			UNION ALL
			SELECT 'write_off', l.good_id, l.batch_id, l.qty, NULL, NULL,
			       p.resolved_by, p.resolved_at, l.line_no
			FROM warehouse_problem_lines l JOIN warehouse_problems p ON p.id = l.problem_id
			WHERE l.load_unit_id = $1::uuid AND p.decision = 'write_off'
			UNION ALL
			SELECT 'return', l.good_id, l.batch_id, l.qty, NULL, NULL,
			       s.created_by, s.posted_at, l.line_no
			FROM supplier_return_shipment_lines l JOIN supplier_return_shipments s ON s.id = l.shipment_id
			WHERE l.load_unit_id = $1::uuid
		) e
		JOIN goods g   ON g.id = e.good_id
		JOIN batches b ON b.id = e.batch_id
		LEFT JOIN users u ON u.id = e.user_id
		ORDER BY e.at, e.ord, g.name`, id)
	if err != nil {
		return nil, fmt.Errorf("состав короба в истории: %w", err)
	}
	defer rows.Close()
	out := []model.LoadUnitContentEvent{}
	for rows.Next() {
		var ev model.LoadUnitContentEvent
		var qty string
		if err := rows.Scan(&ev.Kind, &ev.GoodName, &ev.Uom, &ev.ProductionDate, &qty, &ev.PeerAddress,
			&ev.PeerLoadUnitID, &ev.UserName, &ev.At); err != nil {
			return nil, fmt.Errorf("разобрать изменение состава: %w", err)
		}
		if ev.Qty, err = decimal.NewFromString(qty); err != nil {
			return nil, fmt.Errorf("количество в истории короба: %w", err)
		}
		out = append(out, ev)
	}
	return out, rows.Err()
}

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
			SELECT r.id::text, r.number, u.full_name, s.name, r.posted_at, r.doc_number, r.doc_date
			FROM receipt_lines rl
			JOIN receipts r       ON r.id = rl.receipt_id
			JOIN users u          ON u.id = r.created_by
			LEFT JOIN suppliers s ON s.id = r.supplier_id
			WHERE rl.load_unit_id = $1::uuid
			ORDER BY r.created_at
			LIMIT 1`, id).Scan(&rc.ReceiptID, &rc.Number, &rc.ReceivedBy, &rc.SupplierName, &rc.PostedAt,
			&rc.Doc.Number, &rc.Doc.Date)
		switch {
		case errors.Is(err, pgx.ErrNoRows):
		case err != nil:
			return fmt.Errorf("приёмка короба: %w", err)
		default:
			h.Receipt = &rc
		}

		rows, err := q.Query(ctx, `
			SELECT cf.address, ct.address, p.source, u.full_name, p.placed_at,
			       CASE WHEN m.id IS NOT NULL THEN m.kind
			            WHEN pw.id IS NOT NULL THEN 'putaway'
			            WHEN st.id IS NOT NULL THEN 'stocktake'
			            WHEN r.id IS NOT NULL THEN 'receipt'
			            ELSE '' END,
			       COALESCE(m.number, pw.number, st.number, r.number, 0)
			FROM placements p
			LEFT JOIN cells cf ON cf.id = p.from_cell_id
			JOIN cells ct      ON ct.id = p.to_cell_id
			LEFT JOIN users u  ON u.id = p.user_id
			LEFT JOIN movements m        ON m.id = p.movement_id
			LEFT JOIN putaways pw        ON pw.id = p.putaway_id
			LEFT JOIN receipts r         ON r.id = p.receipt_id
			LEFT JOIN stocktake_cells sc ON sc.id = p.stocktake_cell_id
			LEFT JOIN stocktakes st      ON st.id = sc.stocktake_id
			WHERE p.load_unit_id = $1::uuid
			ORDER BY p.placed_at, p.id`, id)
		if err != nil {
			return fmt.Errorf("переносы короба: %w", err)
		}
		defer rows.Close()
		for rows.Next() {
			var m model.LoadUnitMove
			if err := rows.Scan(&m.FromAddress, &m.ToAddress, &m.Source, &m.UserName, &m.At,
				&m.Operation, &m.OperationNumber); err != nil {
				return fmt.Errorf("разобрать перенос: %w", err)
			}
			h.Moves = append(h.Moves, m)
		}
		if err := rows.Err(); err != nil {
			return err
		}
		rows.Close()
		h.Contents, err = loadUnitContentEvents(ctx, q, id)
		return err
	})
	if err != nil {
		return model.LoadUnitHistory{}, err
	}
	return h, nil
}
