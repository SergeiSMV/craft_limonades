package repository

import (
	"context"
	"errors"
	"fmt"
	"slices"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
)

// problemListLimit - потолок рабочего списка: открытые всегда сверху, решённые - свежие.
// Сотни записей - незаметно; когда решённых станут тысячи, понадобится подгрузка курсором.
const problemListLimit = 500

// ProblemRepository - проблемы склада для офиса (P6-07-3): рабочий список и решение.
type ProblemRepository struct {
	pool *pgxpool.Pool
}

// NewProblemRepository создаёт репозиторий проблем склада.
func NewProblemRepository(pool *pgxpool.Pool) *ProblemRepository {
	return &ProblemRepository{pool: pool}
}

// problemSelect - поля проблемы для списков; порядок совпадает со сканом в [scanProblems].
const problemSelect = `
		SELECT p.id::text, p.number, p.created_at, COALESCE(cu.full_name, ''), COALESCE(c.address, ''),
		       COALESCE(p.load_unit_id::text, ''), p.reason, pr.name, p.comment, COALESCE(p.mark, ''),
		       COALESCE(fw.name, ''), COALESCE(tw.name, ''), COALESCE(fg.name, ''),
		       COALESCE(p.barcode, ''), p.status, COALESCE(p.decision, ''), COALESCE(p.doc_number, ''),
		       COALESCE(to_char(p.doc_date, 'YYYY-MM-DD'), ''), COALESCE(p.supplier_id::text, ''),
		       COALESCE(s.name, ''), COALESCE(t.number, 0), COALESCE(ru.full_name, ''), p.resolved_at,
		       COALESCE(su.full_name, ''), sh.posted_at, COALESCE(sh.number, 0),
		       ARRAY(SELECT ph.id::text FROM problem_photos ph
		             WHERE ph.problem_id = p.id ORDER BY ph.created_at, ph.id),
		       COALESCE(rs.name, ''),
		       -- Варианты, которыми проблему можно решить сейчас (ADHOC-55): активные, по справочнику.
		       ARRAY(SELECT x.id::text FROM problem_reason_resolutions l
		             JOIN problem_resolutions x ON x.id = l.resolution_id
		             WHERE l.reason = p.reason AND x.is_active ORDER BY x.ord),
		       ARRAY(SELECT x.name FROM problem_reason_resolutions l
		             JOIN problem_resolutions x ON x.id = l.resolution_id
		             WHERE l.reason = p.reason AND x.is_active ORDER BY x.ord),
		       ARRAY(SELECT x.action FROM problem_reason_resolutions l
		             JOIN problem_resolutions x ON x.id = l.resolution_id
		             WHERE l.reason = p.reason AND x.is_active ORDER BY x.ord)
		FROM warehouse_problems p
		JOIN problem_reasons pr          ON pr.code = p.reason
		LEFT JOIN problem_resolutions rs ON rs.id = p.resolution_id
		-- У пересорта (ADHOC-53) ячейки и пары складов нет - он лежит, где лежал.
		LEFT JOIN cells c                ON c.id = p.cell_id
		LEFT JOIN internal_warehouses fw ON fw.id = p.from_internal_warehouse_id
		LEFT JOIN internal_warehouses tw ON tw.id = p.to_internal_warehouse_id
		LEFT JOIN goods fg               ON fg.id = p.from_good_id
		LEFT JOIN users cu          ON cu.id = p.created_by
		LEFT JOIN users ru          ON ru.id = p.resolved_by
		LEFT JOIN suppliers s       ON s.id = p.supplier_id
		LEFT JOIN warehouse_tasks t ON t.id = p.return_task_id
		LEFT JOIN supplier_return_shipments sh ON sh.id = p.shipment_id
		LEFT JOIN users su          ON su.id = sh.created_by`

// List - рабочий список офиса: открытые сверху, внутри - свежие первыми.
func (r *ProblemRepository) List(ctx context.Context, f model.ProblemFilter) ([]model.Problem, error) {
	return r.query(ctx, problemSelect+`
		WHERE ($1::text = '' OR p.status = $1)
		ORDER BY p.status = 'open' DESC, p.created_at DESC, p.id
		LIMIT $2`, f.Status, problemListLimit)
}

// Current - открытые проблемы склада для ТСД (ADHOC-35): вкладка «Текущие», свежие первыми.
// Товар - как в рабочем списке офиса: у короба - его состав сейчас, у товара - помеченное.
// Открытых на складе десятки, поэтому без подгрузки - тем же потолком, что у списка офиса.
func (r *ProblemRepository) Current(ctx context.Context) ([]model.Problem, error) {
	return r.query(ctx, problemSelect+`
		WHERE p.status = 'open'
		ORDER BY p.created_at DESC, p.id DESC
		LIMIT $1`, problemListLimit)
}

// Resolved - страница ленты решённых проблем для ТСД (ADHOC-34): свежие решения первыми.
//
// Окно - по времени решения (`[From, To)`); курсор - время решения и id последней показанной
// записи, как у ленты «Завершённые» заданий: при равном времени порядок задаёт id.
func (r *ProblemRepository) Resolved(ctx context.Context, f model.ResolvedProblemsFilter) ([]model.Problem, error) {
	return r.query(ctx, problemSelect+`
		WHERE p.status = 'resolved'
		  AND ($1::timestamptz IS NULL OR p.resolved_at >= $1)
		  AND ($2::timestamptz IS NULL OR p.resolved_at <  $2)
		  AND ($3::timestamptz IS NULL OR (p.resolved_at, p.id) < ($3, NULLIF($4, '')::uuid))
		ORDER BY p.resolved_at DESC, p.id DESC
		LIMIT $5`, f.From, f.To, f.BeforeResolvedAt, f.BeforeID, f.Limit)
}

// query читает проблемы по запросу на [problemSelect] и подкладывает им товар.
func (r *ProblemRepository) query(ctx context.Context, sql string, args ...any) ([]model.Problem, error) {
	rows, err := r.pool.Query(ctx, sql, args...)
	if err != nil {
		return nil, fmt.Errorf("проблемы склада: %w", err)
	}
	out := []model.Problem{}
	index := map[string]int{}
	for rows.Next() {
		var p model.Problem
		var resIDs, resNames, resActions []string
		if err := rows.Scan(&p.ID, &p.Number, &p.CreatedAt, &p.CreatedByName, &p.CellAddress, &p.LoadUnitID,
			&p.Reason, &p.ReasonName, &p.Comment, &p.Mark, &p.FromWarehouse, &p.ToWarehouse, &p.FromGoodName,
			&p.Barcode, &p.Status, &p.Decision,
			&p.DocNumber, &p.DocDate, &p.SupplierID, &p.SupplierName, &p.ReturnTaskNo,
			&p.ResolvedByName, &p.ResolvedAt, &p.ShippedByName, &p.ShippedAt, &p.ShipmentNumber, &p.Photos,
			&p.ResolutionName, &resIDs, &resNames, &resActions); err != nil {
			rows.Close()
			return nil, fmt.Errorf("разобрать проблему: %w", err)
		}
		for i := range resIDs {
			p.Resolutions = append(p.Resolutions, model.ProblemResolution{
				ID: resIDs[i], Name: resNames[i], Action: resActions[i], IsActive: true,
			})
		}
		index[p.ID] = len(out)
		out = append(out, p)
	}
	rows.Close()
	if err := rows.Err(); err != nil || len(out) == 0 {
		return out, err
	}
	if err := r.attachItems(ctx, out, index); err != nil {
		return nil, err
	}
	if err := r.attachMarks(ctx, out, index); err != nil {
		return nil, err
	}
	return out, nil
}

// attachMarks подкладывает проблемам их марки ЧЗ (ADHOC-52).
//
// Ссылка `cz_marks.problem_id` ставится при пометке и после решения не снимается, поэтому
// марки видны и у решённой: офис сверяет с ЧЗ, что именно списали или вернули.
func (r *ProblemRepository) attachMarks(ctx context.Context, problems []model.Problem, index map[string]int) error {
	ids := make([]string, len(problems))
	for i, p := range problems {
		ids[i] = p.ID
	}
	rows, err := r.pool.Query(ctx, `
		SELECT problem_id::text, cis FROM cz_marks
		WHERE problem_id = ANY($1::uuid[])
		ORDER BY problem_id, cis`, ids)
	if err != nil {
		return fmt.Errorf("марки проблем: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var id, cis string
		if err := rows.Scan(&id, &cis); err != nil {
			return fmt.Errorf("разобрать марку проблемы: %w", err)
		}
		p := &problems[index[id]]
		p.Marks = append(p.Marks, cis)
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("марки проблем: %w", err)
	}
	return nil
}

// attachItems подкладывает проблемам товар и подсказку поставщика.
//
// Решённая - что решение взяло (строки решения, с ячейкой). Открытая короб - его состав сейчас
// и ячейка, где он лежит: офис решает судьбу того, что в коробе на деле. Открытая товар - то,
// что помечено, в ячейке пометки. Пересорт (ADHOC-53) - его строки и открытым: что перешло на
// новый товар, записано сразу при перепривязке.
func (r *ProblemRepository) attachItems(ctx context.Context, problems []model.Problem, index map[string]int) error {
	ids := make([]string, len(problems))
	for i, p := range problems {
		ids[i] = p.ID
	}
	rows, err := r.pool.Query(ctx, `
		SELECT p.id::text, g.id::text, COALESCE(g.code, ''), g.name,
		       to_char(b.production_date, 'YYYY-MM-DD'), x.qty::text, c.address,
		       COALESCE(g.supplier_id::text, '')
		FROM warehouse_problems p
		CROSS JOIN LATERAL (
			SELECT l.good_id, l.batch_id, l.qty, l.cell_id, l.line_no AS ord
			FROM warehouse_problem_lines l
			WHERE (p.status = 'resolved' OR p.reason = 'regrade') AND l.problem_id = p.id
			UNION ALL
			SELECT lc.good_id, lc.batch_id, lc.qty, lu.cell_id, 0
			FROM load_units lu JOIN lu_content lc ON lc.load_unit_id = lu.id AND lc.qty > 0
			WHERE p.status = 'open' AND lu.id = p.load_unit_id AND lu.cell_id IS NOT NULL
			UNION ALL
			SELECT p.good_id, p.batch_id, p.qty, p.cell_id, 0
			WHERE p.status = 'open' AND p.good_id IS NOT NULL AND p.reason <> 'regrade'
		) x
		JOIN goods g   ON g.id = x.good_id
		JOIN batches b ON b.id = x.batch_id
		JOIN cells c   ON c.id = x.cell_id
		WHERE p.id = ANY($1::uuid[])
		ORDER BY p.id, x.ord, g.name, b.production_date`, ids)
	if err != nil {
		return fmt.Errorf("товар проблем: %w", err)
	}
	defer rows.Close()

	// Поставщики товара по проблеме: подсказка - только если он один и указан у всех строк.
	suppliers := map[string][]string{}
	for rows.Next() {
		var id, supplier string
		var it model.ProblemItem
		if err := rows.Scan(&id, &it.GoodID, &it.GoodCode, &it.GoodName, &it.ProductionDate,
			&it.Qty, &it.CellAddress, &supplier); err != nil {
			return fmt.Errorf("разобрать товар проблемы: %w", err)
		}
		p := &problems[index[id]]
		p.Items = append(p.Items, it)
		suppliers[id] = append(suppliers[id], supplier)
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("товар проблем: %w", err)
	}
	for id, list := range suppliers {
		if list[0] != "" && !slices.ContainsFunc(list, func(s string) bool { return s != list[0] }) {
			problems[index[id]].SuggestedSupplierID = list[0]
		}
	}
	return nil
}

// lockedProblem - проблема, заблокированная под решение.
type lockedProblem struct {
	id                                                            string
	warehouse, cell, loadUnit, good, batch, toIwh, reason, status string
	qty                                                           decimal.Decimal
}

// problemLine - что решение берёт: товар партии с количеством в ячейке, из короба или россыпью.
type problemLine struct {
	cell, loadUnit, good, batch string
	qty                         decimal.Decimal
}

// Resolve проводит решение офиса по проблеме (P6-07-3) - целиком, одной транзакцией.
//
// Что: находит товар проблемы там, где он лежит сейчас, и по решению списывает его («списать»),
//
//	возвращает в «Основной» («разместить», товар в ячейке приёмки - с заданием на размещение,
//	ADHOC-55) или переводит на склад возврата и кладёт проблему
//	в открытое задание возврата поставщика («возврат»). Взятое пишется строками решения.
//
// Зачем одной транзакцией: решение, движение остатка и задание - один факт; решённая проблема
//
//	без движения или движение без решения разошлись бы со складом.
//
// Как: проблема блокируется строкой (два оператора не решат её дважды), короб - через
// lockPlacedLoadUnits, россыпь - через looseQty; остаток меняется только примитивами
// addStock/removeStock - одна точка для проверки пересчёта (P10).
func (r *ProblemRepository) Resolve(ctx context.Context, in model.ResolveProblemInput) error {
	return WithinTx(ctx, r.pool, func(q Querier) error {
		p, err := lockProblem(ctx, q, in.ProblemID)
		if err != nil {
			return err
		}
		if p.status != model.ProblemStatusOpen {
			return model.ErrProblemResolved
		}
		if in.ResolutionID, err = allowedResolution(ctx, q, p.reason, in.ResolutionID, in.Decision); err != nil {
			return err
		}

		// Пересорт (ADHOC-53) уже перевёл товар при перепривязке и записал строки: решение только
		// связывает его с документом пересортицы 1С.
		if in.Decision == model.ProblemDecisionRegrade {
			return markResolved(ctx, q, in, "")
		}

		lines, err := problemLines(ctx, q, p)
		if err != nil {
			return err
		}

		var taskID string
		switch in.Decision {
		case model.ProblemDecisionWriteOff:
			err = writeOffProblem(ctx, q, p, lines, model.CZMarkWrittenOff)
		case model.ProblemDecisionPlace:
			var to string
			if to, err = defaultInternalWarehouse(ctx, q); err == nil {
				err = relabelProblem(ctx, q, p, lines, to)
			}
			// Товар в ячейке приёмки после снятия метки выносит задание (ADHOC-55).
			if err == nil {
				err = createPutawayTaskForProblem(ctx, q, p.id, p.warehouse, lines)
			}
		case model.ProblemDecisionSupplierReturn:
			taskID, err = returnProblem(ctx, q, p, lines, in)
		default:
			err = model.ErrDecisionNotAllowed
		}
		if err != nil {
			return err
		}

		for i, l := range lines {
			if _, err := q.Exec(ctx, `
				INSERT INTO warehouse_problem_lines
					(problem_id, line_no, cell_id, load_unit_id, good_id, batch_id, qty)
				VALUES ($1::uuid, $2, $3::uuid, NULLIF($4, '')::uuid, $5::uuid, $6::uuid, $7::numeric)`,
				in.ProblemID, i+1, l.cell, l.loadUnit, l.good, l.batch, l.qty.String()); err != nil {
				return fmt.Errorf("записать строку решения: %w", err)
			}
		}
		return markResolved(ctx, q, in, taskID)
	})
}

// allowedResolution - вариант решения, которым офис решает проблему с причиной reason
// (ADHOC-55): активный и допустимый при причине по справочнику, с действием decision.
//
// Прежний клиент шлёт только действие (resolutionID пусто) - тогда берётся первый активный
// вариант причины с этим действием. Нет подходящего - ErrDecisionNotAllowed.
func allowedResolution(ctx context.Context, q Querier, reason, resolutionID, decision string) (string, error) {
	var id string
	err := q.QueryRow(ctx, `
		SELECT x.id::text
		FROM problem_reason_resolutions l
		JOIN problem_resolutions x ON x.id = l.resolution_id
		WHERE l.reason = $1 AND x.is_active AND x.action = $3
		  AND ($2 = '' OR x.id = NULLIF($2, '')::uuid)
		ORDER BY x.ord
		LIMIT 1`, reason, resolutionID, decision).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", model.ErrDecisionNotAllowed
	}
	if err != nil {
		return "", fmt.Errorf("вариант решения причины: %w", err)
	}
	return id, nil
}

// Resolution - вариант решения по id: сервису нужно его действие, чтобы проверить форму решения.
func (r *ProblemRepository) Resolution(ctx context.Context, id string) (model.ProblemResolution, error) {
	return resolutionByID(ctx, r.pool, id)
}

// markResolved записывает решение офиса в проблему: что решили (вариант и его действие),
// документ, поставщик, задание.
func markResolved(ctx context.Context, q Querier, in model.ResolveProblemInput, taskID string) error {
	if _, err := q.Exec(ctx, `
		UPDATE warehouse_problems
		SET status = 'resolved', decision = $2, doc_number = NULLIF($3, ''),
		    doc_date = NULLIF($4, '')::date, supplier_id = NULLIF($5, '')::uuid,
		    return_task_id = NULLIF($6, '')::uuid, resolved_by = $7::uuid, resolved_at = now(),
		    resolution_id = $8::uuid
		WHERE id = $1::uuid`,
		in.ProblemID, in.Decision, in.DocNumber, in.DocDate, in.SupplierID, taskID,
		in.ResolvedBy, in.ResolutionID); err != nil {
		return fmt.Errorf("записать решение: %w", err)
	}
	return nil
}

// lockProblem блокирует проблему под решение.
func lockProblem(ctx context.Context, q Querier, id string) (lockedProblem, error) {
	var p lockedProblem
	var lu, good, batch, qty *string
	err := q.QueryRow(ctx, `
		SELECT warehouse_id::text, COALESCE(cell_id::text, ''), load_unit_id::text, good_id::text,
		       batch_id::text, qty::text, COALESCE(to_internal_warehouse_id::text, ''), reason, status
		FROM warehouse_problems WHERE id = $1::uuid FOR UPDATE`, id).
		Scan(&p.warehouse, &p.cell, &lu, &good, &batch, &qty, &p.toIwh, &p.reason, &p.status)
	if errors.Is(err, pgx.ErrNoRows) {
		return lockedProblem{}, model.ErrProblemNotFound
	}
	if err != nil {
		return lockedProblem{}, fmt.Errorf("прочитать проблему: %w", err)
	}
	p.id = id
	p.loadUnit, p.good, p.batch = deref(lu), deref(good), deref(batch)
	if qty != nil {
		if p.qty, err = decimal.NewFromString(*qty); err != nil {
			return lockedProblem{}, fmt.Errorf("количество проблемы: %w", err)
		}
	}
	return p, nil
}

// problemBoxLines - состав короба проблемы там, где короб лежит сейчас. Короб обязан всё ещё
// принадлежать складу-метке и быть непустым: иначе решать уже нечего.
func problemBoxLines(ctx context.Context, q Querier, p lockedProblem) ([]problemLine, error) {
	boxes, err := lockPlacedLoadUnits(ctx, q, p.loadUnit)
	if errors.Is(err, model.ErrLoadUnitNotPlaced) {
		return nil, model.ErrProblemGoodsMissing
	}
	if err != nil {
		return nil, err
	}
	box := boxes[p.loadUnit]
	if box.iwh != p.toIwh {
		return nil, model.ErrProblemGoodsMissing
	}
	items, err := loadUnitStock(ctx, q, p.loadUnit)
	if err != nil {
		return nil, err
	}
	if len(items) == 0 {
		return nil, model.ErrProblemGoodsMissing
	}
	lines := make([]problemLine, 0, len(items))
	for _, it := range items {
		lines = append(lines, problemLine{cell: box.cell, loadUnit: p.loadUnit, good: it.good, batch: it.batch, qty: it.qty})
	}
	return lines, nil
}

// problemGoodsLines - россыпь товара проблемы на складе-метке. Помеченный товар мог переехать
// (перемещение сохраняет метку), поэтому он берётся там, где лежит: сначала в ячейке пометки,
// дальше по адресам ячеек склада. Товар разных проблем одной партии неразличим - решение берёт
// количество своей проблемы, а не «тот самый» товар.
func problemGoodsLines(ctx context.Context, q Querier, p lockedProblem) ([]problemLine, error) {
	rows, err := q.Query(ctx, `
		SELECT s.cell_id::text
		FROM stock s JOIN cells c ON c.id = s.cell_id
		WHERE c.warehouse_id = $1::uuid AND s.good_id = $2::uuid AND s.batch_id = $3::uuid
		  AND s.internal_warehouse_id = $4::uuid AND s.qty > 0
		ORDER BY s.cell_id = $5::uuid DESC, c.address`,
		p.warehouse, p.good, p.batch, p.toIwh, p.cell)
	if err != nil {
		return nil, fmt.Errorf("найти товар проблемы: %w", err)
	}
	cells, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return nil, fmt.Errorf("найти товар проблемы: %w", err)
	}

	var lines []problemLine
	need := p.qty
	for _, cell := range cells {
		if !need.IsPositive() {
			break
		}
		loose, err := looseQty(ctx, q, cell, p.good, p.batch, p.toIwh)
		if err != nil {
			return nil, err
		}
		if !loose.IsPositive() {
			continue
		}
		take := decimal.Min(loose, need)
		lines = append(lines, problemLine{cell: cell, good: p.good, batch: p.batch, qty: take})
		need = need.Sub(take)
	}
	if need.IsPositive() {
		return nil, model.ErrProblemGoodsMissing
	}
	return lines, nil
}

// writeOffProblem списывает товар проблемы с остатка: строки склада-метки уменьшаются, состав
// короба обнуляется - пустой короб перестаёт быть живым. Марки проблемы уходят со склада
// статусом markStatus (CZ-06): «списана» по решению офиса, «возвращена» отгрузкой возврата.
func writeOffProblem(ctx context.Context, q Querier, p lockedProblem, lines []problemLine, markStatus string) error {
	for _, l := range lines {
		if err := removeStock(ctx, q,
			model.StockKey{CellID: l.cell, GoodID: l.good, BatchID: l.batch, InternalWarehouseID: p.toIwh},
			l.qty); err != nil {
			return err
		}
		if l.loadUnit != "" {
			if err := takeFromLoadUnit(ctx, q, l.loadUnit, l.good, l.batch, l.qty); err != nil {
				return err
			}
		}
	}
	return retireProblemMarks(ctx, q, p, markStatus)
}

// relabelProblem переводит товар проблемы на склад to в тех же ячейках; короб меняет склад
// целиком - дальше он переезжает новым складом.
func relabelProblem(ctx context.Context, q Querier, p lockedProblem, lines []problemLine, to string) error {
	for _, l := range lines {
		if err := transferStock(ctx, q,
			model.StockKey{CellID: l.cell, GoodID: l.good, BatchID: l.batch, InternalWarehouseID: p.toIwh},
			model.StockKey{CellID: l.cell, GoodID: l.good, BatchID: l.batch, InternalWarehouseID: to},
			l.qty); err != nil {
			return err
		}
	}
	if p.loadUnit != "" {
		if _, err := q.Exec(ctx, `UPDATE load_units SET internal_warehouse_id = $2::uuid WHERE id = $1::uuid`,
			p.loadUnit, to); err != nil {
			return fmt.Errorf("сменить склад короба: %w", err)
		}
		return nil
	}
	return relabelProblemMarks(ctx, q, p, to)
}

// returnProblem переводит товар на склад возврата и кладёт проблему в открытое задание возврата
// поставщика. Возвращает задание.
func returnProblem(ctx context.Context, q Querier, p lockedProblem, lines []problemLine, in model.ResolveProblemInput) (string, error) {
	var exists bool
	if err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM suppliers WHERE id = $1::uuid)`,
		in.SupplierID).Scan(&exists); err != nil {
		return "", fmt.Errorf("проверить поставщика: %w", err)
	}
	if !exists {
		return "", model.ErrUnknownSupplier
	}
	var to string
	err := q.QueryRow(ctx, `SELECT id::text FROM internal_warehouses WHERE system_role = $1`,
		model.InternalWarehouseRoleSupplierReturn).Scan(&to)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", model.ErrNoSupplierReturnWarehouse
	}
	if err != nil {
		return "", fmt.Errorf("склад возврата: %w", err)
	}
	if err := relabelProblem(ctx, q, p, lines, to); err != nil {
		return "", err
	}
	return openReturnTask(ctx, q, p.warehouse, in.SupplierID)
}

// openReturnTask - открытое задание возврата поставщику на складе: существующее или новое.
// Одно на поставщика (частичный уникальный индекс): возвраты копятся в нём до отгрузки.
func openReturnTask(ctx context.Context, q Querier, warehouseID, supplierID string) (string, error) {
	var id string
	err := q.QueryRow(ctx, `
		INSERT INTO warehouse_tasks (kind, warehouse_id, supplier_id)
		VALUES ('supplier_return', $1::uuid, $2::uuid)
		ON CONFLICT (warehouse_id, supplier_id) WHERE kind = 'supplier_return' AND status <> 'done'
		DO NOTHING
		RETURNING id::text`, warehouseID, supplierID).Scan(&id)
	if err == nil {
		return id, addTaskEvent(ctx, q, id, model.TaskEventCreated, "", "", "")
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return "", fmt.Errorf("завести задание возврата: %w", err)
	}
	if err := q.QueryRow(ctx, `
		SELECT id::text FROM warehouse_tasks
		WHERE kind = 'supplier_return' AND warehouse_id = $1::uuid AND supplier_id = $2::uuid
		  AND status <> 'done'`, warehouseID, supplierID).Scan(&id); err != nil {
		return "", fmt.Errorf("найти задание возврата: %w", err)
	}
	return id, nil
}
