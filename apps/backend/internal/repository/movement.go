package repository

import (
	"context"
	"errors"
	"fmt"

	"slices"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/movement"
)

// Ошибки переноса ГЕ и проведения документа движения (P6-02). Все — отказ по существу:
// повтор их не исправит.
var (
	// ErrSameCell — ГЕ переносят туда, где она и так лежит.
	ErrSameCell = errors.New("load unit is already in the target cell")
	// ErrMovementPosted — документ движения с этим идентификатором уже проведён.
	ErrMovementPosted = errors.New("movement already posted")
	// ErrEmptyMovement — в документе движения нет ни одной строки.
	ErrEmptyMovement = errors.New("movement has no lines")
	// ErrUnknownMovementKind — вид документа не перемещение и не пополнение.
	ErrUnknownMovementKind = errors.New("unknown movement kind")
	// ErrReceivingCell — ячейка приёмки (С-Н-П) в движении ни источник, ни приёмник: её
	// разносит задание на размещение (P5-02-1), иначе остаток задания разошёлся бы с ячейкой.
	ErrReceivingCell = errors.New("receiving cell is emptied only by a putaway task")
	// ErrEmptyMovementLine — в строке нет ни ГЕ, ни товара.
	// У товара источник и приёмник — ровно по одному: ячейка или короб.
	ErrEmptyMovementLine = errors.New("movement line must have a load unit or goods with one source and one target")
	// ErrSamePlace — товар кладут туда же, откуда взяли: та же ячейка и тот же короб (или
	// россыпь).
	ErrSamePlace = errors.New("goods move to the same place")
	// ErrGoodsShort — в источнике меньше товара этой партии, чем просят перенести. Россыпью
	// считается остаток ячейки за вычетом того, что лежит в её коробах.
	ErrGoodsShort = errors.New("not enough goods at the source")
	// ErrMovementQty — количество товара в строке не положительное.
	ErrMovementQty = errors.New("goods quantity must be positive")
)

// loadUnitTransfer — что нужно, чтобы перенести ГЕ целиком в другую ячейку.
type loadUnitTransfer struct {
	LoadUnitID  string
	ToCellID    string
	WarehouseID string // склад документа: обе ячейки обязаны принадлежать ему
	// Учётная принадлежность состава. Короба на складе лежат в «Основном» — приёмка и
	// размещение кладут туда (уточнение ADR-0016); брак коробом не изолируется.
	InternalWarehouseID string

	// Для журнала размещений: кто и каким документом перенёс.
	Source     string
	UserID     string
	PutawayID  *string
	MovementID *string
}

// transferLoadUnit переносит ГЕ целиком: остаток по её составу переезжает из ячейки, где ГЕ
// числится, в целевую, а место ГЕ и журнал меняет placeLoadUnit (P6-02).
//
// Что: единая функция переноса короба — её зовут размещение (P5-02) и перемещение (P6).
// Зачем: состав ГЕ лежит в остатке её ячейки (приёмка кладёт их вместе), и перенос короба без
//
//	остатка разорвал бы «что в коробе» и «что в ячейке». Две копии этой логики разошлись бы.
//
// Как: строка ГЕ блокируется (FOR UPDATE), состав читается здесь же, в транзакции операции —
//
//	он и есть то, что физически переехало. Остаток двигают общие примитивы stock: через них
//	проходит любое изменение остатка, и проверку пересчёта (P10) добавят в одном месте.
//	Возвращает ячейку, откуда ГЕ взяли, и состав, который переехал: документ «Движение»
//	раскладывает короб по составу на момент переноса (P6-07), а не на конец документа.
func transferLoadUnit(ctx context.Context, q Querier, in loadUnitTransfer) (string, []luStockItem, error) {
	var from *string
	var parent *string
	var hasChildren bool
	err := q.QueryRow(ctx, `
		SELECT cell_id::text, parent_id::text,
		       EXISTS (SELECT 1 FROM load_units c WHERE c.parent_id = lu.id)
		FROM load_units lu WHERE id = $1::uuid FOR UPDATE`, in.LoadUnitID).
		Scan(&from, &parent, &hasChildren)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil, ErrLoadUnitNotFound
	}
	if err != nil {
		return "", nil, fmt.Errorf("прочитать ГЕ: %w", err)
	}
	if from == nil {
		return "", nil, ErrLoadUnitNotPlaced
	}
	// Паллетная логика вне объёма пилота: перенос части дерева разорвал бы место коробов
	// и их остаток.
	if parent != nil || hasChildren {
		return "", nil, ErrLoadUnitNested
	}
	if *from == in.ToCellID {
		return "", nil, ErrSameCell
	}
	if err := guardCellOfWarehouse(ctx, q, in.ToCellID, in.WarehouseID); err != nil {
		return "", nil, err
	}
	if err := guardCellOfWarehouse(ctx, q, *from, in.WarehouseID); err != nil {
		return "", nil, err
	}

	items, err := loadUnitStock(ctx, q, in.LoadUnitID)
	if err != nil {
		return "", nil, err
	}
	for _, c := range items {
		if err := transferStock(ctx, q,
			model.StockKey{CellID: *from, GoodID: c.good, BatchID: c.batch, InternalWarehouseID: in.InternalWarehouseID},
			model.StockKey{CellID: in.ToCellID, GoodID: c.good, BatchID: c.batch, InternalWarehouseID: in.InternalWarehouseID},
			c.qty); err != nil {
			return "", nil, err
		}
	}

	if err := placeLoadUnit(ctx, q, model.PlaceLoadUnitInput{
		LoadUnitID: in.LoadUnitID,
		CellID:     in.ToCellID,
		Source:     in.Source,
		UserID:     in.UserID,
		PutawayID:  in.PutawayID,
		MovementID: in.MovementID,
	}); err != nil {
		return "", nil, err
	}
	return *from, items, nil
}

// luStockItem — позиция состава ГЕ: товар, партия, количество.
type luStockItem struct {
	good, batch string
	qty         decimal.Decimal
}

// loadUnitStock читает непустой состав ГЕ. Строки читаются целиком до переноса: курсор
// и запись остатка в одной транзакции на одном соединении не уживаются.
func loadUnitStock(ctx context.Context, q Querier, loadUnitID string) ([]luStockItem, error) {
	rows, err := q.Query(ctx, `
		SELECT good_id::text, batch_id::text, qty::text
		FROM lu_content WHERE load_unit_id = $1::uuid AND qty > 0`, loadUnitID)
	if err != nil {
		return nil, fmt.Errorf("прочитать состав ГЕ: %w", err)
	}
	defer rows.Close()

	var items []luStockItem
	for rows.Next() {
		var c luStockItem
		var qty string
		if err := rows.Scan(&c.good, &c.batch, &qty); err != nil {
			return nil, fmt.Errorf("разобрать состав ГЕ: %w", err)
		}
		if c.qty, err = decimal.NewFromString(qty); err != nil {
			return nil, fmt.Errorf("количество в составе ГЕ: %w", err)
		}
		items = append(items, c)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("прочитать состав ГЕ: %w", err)
	}
	return items, nil
}

// MovementLineInput — строка документа движения: ГЕ целиком ЛИБО товар.
//
// ГЕ целиком: LoadUnitID и ToCellID; ячейку-источник сервер берёт из места ГЕ.
// Товар: товар, дата выпуска партии, количество; источник — ячейка (россыпь) ИЛИ короб,
// приёмник — ячейка (россыпь) ИЛИ короб. У короба ячейка известна, её не шлют.
type MovementLineInput struct {
	LoadUnitID string

	GoodID         string
	ProductionDate string // ISO 'YYYY-MM-DD'
	Qty            decimal.Decimal
	FromCellID     string
	FromLoadUnitID string
	ToLoadUnitID   string

	ToCellID string
}

// MovementSubmitInput — документ движения, собранный устройством целиком (P6-01).
type MovementSubmitInput struct {
	MovementID  string
	Kind        string // model.MovementMove | model.MovementReplenish
	WarehouseID string
	CreatedBy   string
	Lines       []MovementLineInput
}

// movementSubmit проводит документ движения целиком на Querier (P6-02).
//
// Что: шапка документа и строки; ГЕ целиком переезжает вместе с остатком по составу.
// Зачем одной транзакцией: документ — одно «Движение» для 1С; отклонённая строка в цепочке
//
//	дала бы проведённый документ без неё — тот же урок, что у приёмки и размещения.
//
// Перемещение и пополнение проводятся одинаково и различаются только видом в шапке (P6-05):
// пополнение — то же перемещение товара или короба, оно не ограничено ни сочетанием
// источника и приёмника, ни ветвью строки.
//
// Как: строки идут по порядку ТСД; любая ошибка откатывает весь документ. Повтор с тем же
//
//	документом упирается в первичный ключ и даёт ErrMovementPosted. Одну ГЕ можно перенести
//	в документе дважды (A → B → C): вторая строка берёт её оттуда, куда положила первая.
//	Каждая строка отдаёт товарные движения — что и откуда куда переехало на её шаге; по ним
//	в конце той же транзакции публикуется «Движение» для 1С (P6-07).
func movementSubmit(ctx context.Context, q Querier, in MovementSubmitInput) (int, error) {
	if in.Kind != model.MovementMove && in.Kind != model.MovementReplenish {
		return 0, ErrUnknownMovementKind
	}
	if len(in.Lines) == 0 {
		return 0, ErrEmptyMovement
	}
	if _, err := q.Exec(ctx, `
		INSERT INTO movements (id, kind, warehouse_id, created_by)
		VALUES ($1::uuid, $2, $3::uuid, $4::uuid)`,
		in.MovementID, in.Kind, in.WarehouseID, in.CreatedBy); err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return 0, ErrMovementPosted
		}
		return 0, fmt.Errorf("открыть документ движения: %w", err)
	}

	iwh, err := defaultInternalWarehouse(ctx, q)
	if err != nil {
		return 0, err
	}
	var moves []movement.Move
	for i, ln := range in.Lines {
		var step []movement.Move
		var err error
		if ln.LoadUnitID != "" {
			step, err = movementLoadUnit(ctx, q, in, i+1, ln, iwh)
		} else {
			step, err = movementGoods(ctx, q, in, i+1, ln, iwh)
		}
		if err != nil {
			return 0, err
		}
		moves = append(moves, step...)
	}
	if err := saveMovementDocument(ctx, q, in.MovementID, moves); err != nil {
		return 0, err
	}
	return len(in.Lines), nil
}

// movementLoadUnit переносит ГЕ целиком и пишет строку документа. Так двигают короб и
// перемещение, и пополнение (P6-05): пополнить нижнюю ячейку можно и целым коробом.
//
// Ячейку приёмки приёмник проверяет до переноса, источник — после: где лежит ГЕ, узнаёт
// transferLoadUnit под блокировкой, а отказ всё равно откатывает перенос вместе с документом.
//
// Возвращает состав короба товарными движениями «откуда → куда»: именно он переехал на этом
// шаге, даже если дальше в документе в короб доложат или из него возьмут.
func movementLoadUnit(ctx context.Context, q Querier, in MovementSubmitInput, lineNo int, ln MovementLineInput, iwh string) ([]movement.Move, error) {
	if ln.ToCellID == "" {
		return nil, ErrEmptyMovementLine
	}
	if err := guardNotReceivingCell(ctx, q, ln.ToCellID); err != nil {
		return nil, err
	}
	from, items, err := transferLoadUnit(ctx, q, loadUnitTransfer{
		LoadUnitID:          ln.LoadUnitID,
		ToCellID:            ln.ToCellID,
		WarehouseID:         in.WarehouseID,
		InternalWarehouseID: iwh,
		Source:              model.PlacementMove,
		UserID:              in.CreatedBy,
		MovementID:          &in.MovementID,
	})
	if err != nil {
		return nil, err
	}
	if err := guardNotReceivingCell(ctx, q, from); err != nil {
		return nil, err
	}
	if _, err := q.Exec(ctx, `
		INSERT INTO movement_lines (movement_id, line_no, load_unit_id, from_cell_id, to_cell_id)
		VALUES ($1::uuid, $2, $3::uuid, $4::uuid, $5::uuid)`,
		in.MovementID, lineNo, ln.LoadUnitID, from, ln.ToCellID); err != nil {
		return nil, fmt.Errorf("записать строку движения: %w", err)
	}
	moves := make([]movement.Move, 0, len(items))
	for _, c := range items {
		moves = append(moves, movement.Move{
			FromCellID: from, ToCellID: ln.ToCellID, GoodID: c.good, BatchID: c.batch, Qty: c.qty,
		})
	}
	return moves, nil
}

// movementGoods переносит товар между ячейками и коробами и пишет строку документа (P6-03).
//
// Что: источник — россыпь ячейки или короб, приёмник — россыпь ячейки или короб, в любых
//
//	сочетаниях. Так устроены и перемещение товара, и пополнение (решение 2026-10-13).
//
// Как: короба блокируются по порядку идентификаторов — два документа с теми же коробами
//
//	не сцепятся намертво; ячейка короба — его текущее место. Наличие проверяется под
//	блокировкой: россыпь — строка остатка минус её короба, короб — строка состава. Состав
//	коробов меняется прямо, остаток ячеек — общими примитивами stock и только между разными
//	ячейками: из короба в россыпь той же ячейки остаток ячейки не меняется.
func movementGoods(ctx context.Context, q Querier, in MovementSubmitInput, lineNo int, ln MovementLineInput, iwh string) ([]movement.Move, error) {
	// Источник и приёмник — ровно по одному: ячейка (россыпь) или короб.
	if ln.GoodID == "" ||
		(ln.FromCellID == "") == (ln.FromLoadUnitID == "") ||
		(ln.ToCellID == "") == (ln.ToLoadUnitID == "") {
		return nil, ErrEmptyMovementLine
	}
	if !ln.Qty.IsPositive() {
		return nil, ErrMovementQty
	}
	batchID, err := existingBatch(ctx, q, ln.GoodID, ln.ProductionDate)
	if err != nil {
		return nil, err
	}

	cells, err := lockPlacedLoadUnits(ctx, q, ln.FromLoadUnitID, ln.ToLoadUnitID)
	if err != nil {
		return nil, err
	}
	fromCell, toCell := ln.FromCellID, ln.ToCellID
	if ln.FromLoadUnitID != "" {
		fromCell = cells[ln.FromLoadUnitID]
	}
	if ln.ToLoadUnitID != "" {
		toCell = cells[ln.ToLoadUnitID]
	}
	if fromCell == toCell && ln.FromLoadUnitID == ln.ToLoadUnitID {
		return nil, ErrSamePlace
	}
	if err := guardCellOfWarehouse(ctx, q, fromCell, in.WarehouseID); err != nil {
		return nil, err
	}
	if err := guardCellOfWarehouse(ctx, q, toCell, in.WarehouseID); err != nil {
		return nil, err
	}
	for _, cell := range []string{fromCell, toCell} {
		if err := guardNotReceivingCell(ctx, q, cell); err != nil {
			return nil, err
		}
	}

	// Источник: хватает ли товара — под блокировкой той строки, из которой он уйдёт.
	if ln.FromLoadUnitID != "" {
		if err := takeFromLoadUnit(ctx, q, ln.FromLoadUnitID, ln.GoodID, batchID, ln.Qty); err != nil {
			return nil, err
		}
	} else {
		loose, err := looseQty(ctx, q, fromCell, ln.GoodID, batchID, iwh)
		if err != nil {
			return nil, err
		}
		if loose.LessThan(ln.Qty) {
			return nil, ErrGoodsShort
		}
	}
	if ln.ToLoadUnitID != "" {
		if _, err := q.Exec(ctx, `
			INSERT INTO lu_content (load_unit_id, good_id, batch_id, qty)
			VALUES ($1::uuid, $2::uuid, $3::uuid, $4::numeric)
			ON CONFLICT (load_unit_id, good_id, batch_id) DO UPDATE SET qty = lu_content.qty + EXCLUDED.qty`,
			ln.ToLoadUnitID, ln.GoodID, batchID, ln.Qty.String()); err != nil {
			return nil, fmt.Errorf("положить товар в короб: %w", err)
		}
	}
	if fromCell != toCell {
		if err := transferStock(ctx, q,
			model.StockKey{CellID: fromCell, GoodID: ln.GoodID, BatchID: batchID, InternalWarehouseID: iwh},
			model.StockKey{CellID: toCell, GoodID: ln.GoodID, BatchID: batchID, InternalWarehouseID: iwh},
			ln.Qty); err != nil {
			return nil, err
		}
	}

	if _, err := q.Exec(ctx, `
		INSERT INTO movement_lines
			(movement_id, line_no, good_id, batch_id, qty, internal_warehouse_id,
			 from_load_unit_id, to_load_unit_id, from_cell_id, to_cell_id)
		VALUES ($1::uuid, $2, $3::uuid, $4::uuid, $5::numeric, $6::uuid,
		        NULLIF($7, '')::uuid, NULLIF($8, '')::uuid, $9::uuid, $10::uuid)`,
		in.MovementID, lineNo, ln.GoodID, batchID, ln.Qty.String(), iwh,
		ln.FromLoadUnitID, ln.ToLoadUnitID, fromCell, toCell); err != nil {
		return nil, fmt.Errorf("записать строку движения: %w", err)
	}
	return []movement.Move{{
		FromCellID: fromCell, ToCellID: toCell, GoodID: ln.GoodID, BatchID: batchID, Qty: ln.Qty,
	}}, nil
}

// guardNotReceivingCell отклоняет ячейку приёмки (`cells.is_default`) в движении (P6-05).
//
// Что: ячейка приёмки — не источник и не приёмник перемещения и пополнения.
// Зачем: её содержимое разносит задание на размещение, и остаток задания считается по сеансам
//
//	размещения (P5-02-1). Движение мимо задания оставило бы задание с товаром, которого
//	в ячейке уже нет, — или положило бы туда товар без задания. Терминал такую ячейку не
//	предлагает, но инвариант задания держит тот, кто хранит задание: старая сборка
//	приложения, ошибка в новом экране или другая операция пришлют такую строку мимо ТСД.
//	Запрет — по ячейке, а не по заданию: размещённое по заданию дальше движется свободно.
//
// Как: ячейку ищем по флагу, а не по адресу «С-Н-П» — так же, как приёмка и размещение.
func guardNotReceivingCell(ctx context.Context, q Querier, cellID string) error {
	var receiving bool
	err := q.QueryRow(ctx, `SELECT is_default FROM cells WHERE id = $1::uuid`, cellID).Scan(&receiving)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrUnknownReference
	}
	if err != nil {
		return fmt.Errorf("проверить ячейку приёмки: %w", err)
	}
	if receiving {
		return ErrReceivingCell
	}
	return nil
}

// existingBatch находит партию товара по дате выпуска. Перемещение партий не заводит: товара
// партии, которой нет, нет и в источнике.
func existingBatch(ctx context.Context, q Querier, goodID, productionDate string) (string, error) {
	var id string
	err := q.QueryRow(ctx, `
		SELECT id::text FROM batches WHERE good_id = $1::uuid AND production_date = $2::date`,
		goodID, productionDate).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrGoodsShort
	}
	if err != nil {
		return "", fmt.Errorf("найти партию: %w", err)
	}
	return id, nil
}

// lockPlacedLoadUnits блокирует непустые идентификаторы коробов по порядку и возвращает их
// ячейки. Короб обязан лежать на складе и не быть частью паллеты.
func lockPlacedLoadUnits(ctx context.Context, q Querier, ids ...string) (map[string]string, error) {
	var want []string
	for _, id := range ids {
		if id != "" && !slices.Contains(want, id) {
			want = append(want, id)
		}
	}
	slices.Sort(want)
	cells := make(map[string]string, len(want))
	for _, id := range want {
		var cell, parent *string
		var hasChildren bool
		err := q.QueryRow(ctx, `
			SELECT cell_id::text, parent_id::text,
			       EXISTS (SELECT 1 FROM load_units c WHERE c.parent_id = lu.id)
			FROM load_units lu WHERE id = $1::uuid FOR UPDATE`, id).Scan(&cell, &parent, &hasChildren)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrLoadUnitNotFound
		}
		if err != nil {
			return nil, fmt.Errorf("прочитать короб: %w", err)
		}
		if cell == nil {
			return nil, ErrLoadUnitNotPlaced
		}
		if parent != nil || hasChildren {
			return nil, ErrLoadUnitNested
		}
		cells[id] = *cell
	}
	return cells, nil
}

// takeFromLoadUnit уменьшает состав короба на qty, если товара этой партии в нём хватает.
// Строка состава остаётся и с нулём — как строка остатка: пустая позиция короба не удаляется.
func takeFromLoadUnit(ctx context.Context, q Querier, loadUnitID, goodID, batchID string, qty decimal.Decimal) error {
	tag, err := q.Exec(ctx, `
		UPDATE lu_content SET qty = qty - $4::numeric
		WHERE load_unit_id = $1::uuid AND good_id = $2::uuid AND batch_id = $3::uuid AND qty >= $4::numeric`,
		loadUnitID, goodID, batchID, qty.String())
	if err != nil {
		return fmt.Errorf("взять товар из короба: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrGoodsShort
	}
	return nil
}

// looseQty — россыпь товара партии в ячейке: остаток за вычетом того, что лежит в её коробах.
// Строка остатка блокируется до подсчёта: иначе два документа увидели бы одну и ту же россыпь
// и вместе забрали бы товар из-под короба. Тот же расчёт, что у россыпи размещения (P5-02).
func looseQty(ctx context.Context, q Querier, cellID, goodID, batchID, iwh string) (decimal.Decimal, error) {
	var loose decimal.Decimal
	err := q.QueryRow(ctx, `
		WITH locked AS (
			SELECT qty FROM stock
			WHERE cell_id = $1::uuid AND good_id = $2::uuid AND batch_id = $3::uuid
			  AND internal_warehouse_id = $4::uuid
			FOR UPDATE
		)
		SELECT COALESCE((SELECT qty FROM locked), 0)
		     - COALESCE((SELECT sum(c.qty) FROM lu_content c
		                 JOIN load_units lu ON lu.id = c.load_unit_id
		                 WHERE lu.cell_id = $1::uuid AND c.good_id = $2::uuid
		                   AND c.batch_id = $3::uuid), 0)`,
		cellID, goodID, batchID, iwh).Scan(&loose)
	if err != nil {
		return decimal.Zero, fmt.Errorf("посчитать россыпь: %w", err)
	}
	return loose, nil
}
