package repository

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
)

// Ошибки проведения размещения (P5-02). Все - отказ по существу: повтор их не исправит.
var (
	// ErrPutawayPosted - сеанс с этим идентификатором уже проведён (другой операцией).
	ErrPutawayPosted = errors.New("putaway already posted")
	// ErrEmptyPutaway - в сеансе нет ни одной строки.
	ErrEmptyPutaway = errors.New("putaway has no lines")
	// ErrPutawaySameCell - строка кладёт товар туда же, откуда взяла.
	ErrPutawaySameCell = errors.New("putaway line moves to the same cell")
	// ErrForeignCell - ячейка принадлежит другому складу, не складу документа.
	ErrForeignCell = errors.New("cell belongs to another warehouse")
	// ErrLoadUnitNotPlaced - короб ещё не лежит на складе (не оприходован приёмкой).
	ErrLoadUnitNotPlaced = errors.New("load unit is not placed")
	// ErrLoadUnitNested - короб вложен в паллету или сам содержит короба. Паллетная логика вне
	// объёма пилота, а частичный перенос дерева разорвал бы место коробов и их остаток.
	ErrLoadUnitNested = errors.New("nested load units are not supported")
	// ErrLooseStockShort - россыпи в ячейке приёмки меньше, чем просят разместить. Товар,
	// лежащий там же в коробах, россыпью не считается: иначе остаток ушёл бы из-под короба,
	// и его состав разошёлся бы с тем, что числится в ячейке.
	ErrLooseStockShort = errors.New("not enough loose stock in the receiving cell")
)

// PutawayLineInput - строка размещения: короб целиком ЛИБО россыпь.
type PutawayLineInput struct {
	LoadUnitID string // короб; пусто - россыпь

	// Россыпь: товар, дата выпуска партии (ISO 'YYYY-MM-DD') и количество.
	GoodID         string
	ProductionDate string
	Qty            decimal.Decimal

	ToCellID string

	// Marks - КИ марок ЧЗ строки россыпи (CZ-06): у маркируемого товара обязательны, по одной
	// на единицу; марки переезжают из ячейки приёмки вместе с остатком.
	Marks []string
}

// PutawaySubmitInput - сеанс размещения, собранный устройством целиком (P5-02).
//
// TaskID обязателен: размещения без задания нет (P5-02-1).
type PutawaySubmitInput struct {
	PutawayID   string
	TaskID      string
	WarehouseID string
	CreatedBy   string
	Lines       []PutawayLineInput
}

// putawaySubmit проводит сеанс размещения целиком на Querier (P5-02).
//
// Что: короба переезжают из своей ячейки в ячейку хранения вместе с остатком по их составу;
//
//	россыпь переезжает из ячейки приёмки (дефолтной ячейки склада). Всё - в склад
//	по умолчанию («Основной»): брак уходит отдельной дорогой («Проблемы склада», P6).
//
// Зачем одной транзакцией: строки сеанса - один документ «Движение». Отклонённая строка
//
//	в цепочке операций дала бы проведённый документ без неё - тот же урок, что у приёмки.
//
// Как: строки идут по порядку ТСД; любая ошибка откатывает весь сеанс. Повтор с тем же
//
//	документом упирается в первичный ключ и даёт ErrPutawayPosted.
func putawaySubmit(ctx context.Context, q Querier, in PutawaySubmitInput) (int, error) {
	if len(in.Lines) == 0 {
		return 0, ErrEmptyPutaway
	}
	if err := lockTaskForPutaway(ctx, q, in.TaskID, in.WarehouseID); err != nil {
		return 0, err
	}
	rem, err := loadTaskRemainder(ctx, q, in.TaskID)
	if err != nil {
		return 0, err
	}
	if _, err := q.Exec(ctx, `
		INSERT INTO putaways (id, task_id, warehouse_id, created_by)
		VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid)`,
		in.PutawayID, in.TaskID, in.WarehouseID, in.CreatedBy); err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return 0, ErrPutawayPosted
		}
		return 0, fmt.Errorf("открыть документ размещения: %w", err)
	}

	iwh, err := defaultInternalWarehouse(ctx, q)
	if err != nil {
		return 0, err
	}
	// Ячейку приёмки ищем один раз и только если есть россыпь: сеанс из одних коробов не должен
	// зависеть от её наличия.
	var receivingCell string

	// Строки проверяются все, а не до первой плохой (ADHOC-40): каждая - под своей точкой
	// отката. Остаток задания в памяти отклонённая строка не трогает - он восстанавливается,
	// иначе следующая строка упёрлась бы в «больше, чем осталось» из-за строки, которой нет.
	var bad []LineRejection
	for i, ln := range in.Lines {
		undo := rem.snapshot()
		rejected, err := tryLine(ctx, q, func() error {
			if err := guardCellOfWarehouse(ctx, q, ln.ToCellID, in.WarehouseID); err != nil {
				return err
			}
			var row putawayLineRow
			var err error
			if ln.LoadUnitID != "" {
				// Короб задания, ещё не размещённый им. Отметка сразу: второй раз в том же
				// сеансе тот же короб - уже не позиция задания.
				if !rem.boxes[ln.LoadUnitID] {
					return ErrNotInTask
				}
				rem.boxes[ln.LoadUnitID] = false
				row, err = putawayLoadUnit(ctx, q, in, ln)
			} else {
				if receivingCell == "" {
					receivingCell, err = defaultCellID(ctx, q, in.WarehouseID)
					if errors.Is(err, ErrNotFound) {
						return ErrNoDefaultCell
					}
					if err != nil {
						return err
					}
				}
				var batchID string
				batchID, err = taskBatch(ctx, q, ln, rem)
				if err != nil {
					return err
				}
				row, err = putawayLoose(ctx, q, ln, batchID, receivingCell, iwh)
			}
			if err != nil {
				return err
			}
			return insertPutawayLine(ctx, q, in.PutawayID, i+1, row)
		})
		if err != nil {
			return 0, err
		}
		if rejected != nil {
			undo()
			bad = append(bad, LineRejection{Line: i + 1, Label: putawayLineText(ctx, q, ln), Err: rejected})
		}
	}
	if len(bad) > 0 {
		return 0, &DocumentLinesError{Total: len(in.Lines), Lines: bad}
	}
	// «Движение» для 1С - в этой же транзакции: проведённого сеанса без документа не бывает,
	// как и документа без сеанса (P5-04).
	if err := savePutawayDocument(ctx, q, in.PutawayID); err != nil {
		return 0, err
	}
	if err := addTaskEvent(ctx, q, in.TaskID, model.TaskEventSession, in.CreatedBy, "", in.PutawayID); err != nil {
		return 0, err
	}
	if err := settleTaskAfterPutaway(ctx, q, in.TaskID, in.CreatedBy); err != nil {
		return 0, err
	}
	return len(in.Lines), nil
}

// taskBatch находит партию строки россыпи среди позиций задания и списывает с остатка задания
// её количество. Партия задания - единственная, которую можно разместить: россыпь этой даты
// не из задания размещается не здесь.
func taskBatch(ctx context.Context, q Querier, ln PutawayLineInput, rem taskRemainder) (string, error) {
	var batchID string
	err := q.QueryRow(ctx, `
		SELECT id::text FROM batches WHERE good_id = $1::uuid AND production_date = $2::date`,
		ln.GoodID, ln.ProductionDate).Scan(&batchID)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNotInTask
	}
	if err != nil {
		return "", fmt.Errorf("найти партию: %w", err)
	}
	key := [2]string{ln.GoodID, batchID}
	left, ok := rem.loose[key]
	if !ok {
		return "", ErrNotInTask
	}
	if left.LessThan(ln.Qty) {
		return "", ErrExceedsTask
	}
	rem.loose[key] = left.Sub(ln.Qty)
	return batchID, nil
}

// putawayLineRow - строка документа в том виде, в каком она ложится в putaway_lines.
type putawayLineRow struct {
	loadUnitID *string
	goodID     *string
	batchID    *string
	qty        *string
	fromCellID string
	toCellID   string
	marks      []string // КИ марок россыпи (ADHOC-55); у короба - пусто, его марки в составе
}

// putawayLoadUnit переносит короб задания целиком в ячейку хранения - общей функцией переноса
// ГЕ (P6-02) с источником «размещение» и ссылкой на сеанс.
func putawayLoadUnit(ctx context.Context, q Querier, in PutawaySubmitInput, ln PutawayLineInput) (putawayLineRow, error) {
	from, _, err := transferLoadUnit(ctx, q, loadUnitTransfer{
		LoadUnitID:  ln.LoadUnitID,
		ToCellID:    ln.ToCellID,
		WarehouseID: in.WarehouseID,
		Source:      model.PlacementPutaway,
		UserID:      in.CreatedBy,
		PutawayID:   &in.PutawayID,
	})
	if errors.Is(err, ErrSameCell) {
		return putawayLineRow{}, ErrPutawaySameCell
	}
	if err != nil {
		return putawayLineRow{}, err
	}
	lu := ln.LoadUnitID
	return putawayLineRow{loadUnitID: &lu, fromCellID: from, toCellID: ln.ToCellID}, nil
}

// putawayLoose переносит россыпь из ячейки приёмки.
//
// Россыпь - это остаток ячейки за вычетом того, что лежит в ней же в коробах того же склада
// (looseQty, общий с перемещением). Строка остатка блокируется до проверки: иначе два сеанса
// одновременно увидели бы одну и ту же россыпь и вместе забрали бы товар из-под короба.
func putawayLoose(ctx context.Context, q Querier, ln PutawayLineInput, batchID, from, iwh string) (putawayLineRow, error) {
	if from == ln.ToCellID {
		return putawayLineRow{}, ErrPutawaySameCell
	}

	loose, err := looseQty(ctx, q, from, ln.GoodID, batchID, iwh)
	if err != nil {
		return putawayLineRow{}, err
	}
	if loose.LessThan(ln.Qty) {
		return putawayLineRow{}, ErrLooseStockShort
	}

	if err := transferStock(ctx, q,
		model.StockKey{CellID: from, GoodID: ln.GoodID, BatchID: batchID, InternalWarehouseID: iwh},
		model.StockKey{CellID: ln.ToCellID, GoodID: ln.GoodID, BatchID: batchID, InternalWarehouseID: iwh},
		ln.Qty); err != nil {
		return putawayLineRow{}, err
	}
	if err := moveMarks(ctx, q, ln.GoodID, batchID, ln.Marks, ln.Qty,
		placeOf("", from, iwh), placeOf("", ln.ToCellID, iwh)); err != nil {
		return putawayLineRow{}, err
	}
	good, qty := ln.GoodID, ln.Qty.String()
	return putawayLineRow{
		goodID: &good, batchID: &batchID, qty: &qty, fromCellID: from, toCellID: ln.ToCellID,
		marks: ln.Marks,
	}, nil
}

// transferStock переносит остаток между ячейками на Querier - расход и приход в транзакции
// вызывающего. Тот же примитив, что StockRepository.Transfer, но без своей транзакции.
func transferStock(ctx context.Context, q Querier, from, to model.StockKey, qty decimal.Decimal) error {
	if err := removeStock(ctx, q, from, qty); err != nil {
		return err
	}
	return addStock(ctx, q, to, qty)
}

// guardCellOfWarehouse проверяет, что ячейка есть и принадлежит складу документа.
func guardCellOfWarehouse(ctx context.Context, q Querier, cellID, warehouseID string) error {
	var wh string
	err := q.QueryRow(ctx, `SELECT warehouse_id::text FROM cells WHERE id = $1::uuid`, cellID).Scan(&wh)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrUnknownReference
	}
	if err != nil {
		return fmt.Errorf("проверить ячейку: %w", err)
	}
	if wh != warehouseID {
		return ErrForeignCell
	}
	return nil
}

// insertPutawayLine записывает строку документа размещения.
func insertPutawayLine(ctx context.Context, q Querier, putawayID string, lineNo int, row putawayLineRow) error {
	_, err := q.Exec(ctx, `
		INSERT INTO putaway_lines
			(putaway_id, line_no, load_unit_id, good_id, batch_id, qty, from_cell_id, to_cell_id, marks)
		VALUES ($1::uuid, $2, $3::uuid, $4::uuid, $5::uuid, $6::numeric, $7::uuid, $8::uuid, $9::text[])`,
		putawayID, lineNo, row.loadUnitID, row.goodID, row.batchID, row.qty, row.fromCellID, row.toCellID,
		nonNilMarks(row.marks))
	if err != nil {
		return fmt.Errorf("записать строку размещения: %w", err)
	}
	return nil
}

// putawayLineText - строка размещения для человека (ADHOC-40): «короб → ячейка» или
// «товар · партия · количество → ячейка» (россыпь всегда из ячейки приёмки).
func putawayLineText(ctx context.Context, q Querier, ln PutawayLineInput) string {
	to := cellText(ctx, q, ln.ToCellID)
	if ln.LoadUnitID != "" {
		return boxText(ctx, q, ln.LoadUnitID) + " → " + to
	}
	return goodText(ctx, q, ln.GoodID, ln.ProductionDate, ln.Qty) + " → " + to
}
