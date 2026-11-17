package repository

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/model"
)

// Типы операций очереди устройства. Значения совпадают со строками, которыми клиент пишет тип
// в свою очередь (`OutboxKind.wire`): тип едет по сети как есть, и расхождение здесь означало бы
// молча неисполняемую операцию.
const (
	KindBindBarcode   = "bind_barcode"
	KindUnbindBarcode = "unbind_barcode"

	// Ввод остатков: старт сессии по идентификатору устройства, checkpoint ячейки, финал.
	KindStockEntryStart      = "stock_entry_start"
	KindStockEntryCheckpoint = "stock_entry_checkpoint"
	KindStockEntryFinalize   = "stock_entry_finalize"

	// Приёмка целиком: документ, его ГЕ, строки и оприходование - одна операция (P4-09).
	KindReceiptSubmit = "receipt_submit"

	// Размещение целиком: сеанс разноса коробов и россыпи по ячейкам - одна операция (P5-02).
	KindPutawaySubmit = "putaway_submit"

	// Движение целиком: документ перемещения или пополнения - одна операция (P6-03).
	KindMovementSubmit = "movement_submit"

	// Проблема склада: пометка короба или товара другим внутренним складом (P6-07-1).
	KindProblemSubmit = "problem_submit"

	// Отгрузка возврата поставщику: сеанс по заданию supplier_return - одна операция (ADHOC-31).
	KindReturnSubmit = "return_submit"
)

// LoadUnitInput - грузовая единица, собранная на приёмке: идентификатор из QR ярлыка и вид.
// CZCode - короб ЧЗ (`00`+SSCC), которым является ГЕ (CZ-05): id ей выдало устройство, ярлыка нет.
type LoadUnitInput struct {
	ID     string
	Kind   string
	CZCode string
}

// ReceiptSubmitInput - приёмка, собранная устройством целиком.
//
// Строки с пустой ячейкой ложатся в ячейку по умолчанию склада документа.
type ReceiptSubmitInput struct {
	ReceiptID   string
	WarehouseID string
	SupplierID  string // пусто - без поставщика
	CreatedBy   string
	Doc         model.SupplierDoc // накладная поставщика (ADHOC-23)
	LoadUnits   []LoadUnitInput
	Lines       []model.ReceiptLineInput
	CZGroups    []model.CZAggregate // групповые упаковки ЧЗ приёмки (CZ-05)
}

// OperationsRepository - применение операций очереди устройства под ключом идемпотентности.
//
// Что: на каждую операцию - своя транзакция, в которой лежат и эффект, и пометка в журнале.
// Зачем: повтор операции не должен применять эффект второй раз (P2-05), а пометка без эффекта
//
//	(или наоборот) вернула бы ту же беду при падении между ними.
//
// Как: WithinTx { once(operation_id) { эффект } } - эффект выполняется через те же
//
//	Querier-хелперы, что и обычные ручки, поэтому поведение операции из очереди и операции
//	из прямого вызова совпадает по определению, а не по недосмотру.
type OperationsRepository struct {
	pool *pgxpool.Pool
}

// NewOperationsRepository создаёт репозиторий применения операций очереди.
func NewOperationsRepository(pool *pgxpool.Pool) *OperationsRepository {
	return &OperationsRepository{pool: pool}
}

// BindBarcode применяет привязку ШК под ключом идемпотентности.
func (r *OperationsRepository) BindBarcode(ctx context.Context, operationID string, in BarcodeBindInput) (Applied, error) {
	return r.inTx(ctx, operationID, KindBindBarcode, func(q Querier) (json.RawMessage, error) {
		if err := bindBarcode(ctx, q, in.GoodID, in.Barcode, in.Symbology); err != nil {
			return nil, err
		}
		// ШК из марки ЧЗ - товар маркируемый (CZ-05): в той же транзакции, что и привязка.
		if in.FromCZMark {
			return nil, markGoodsCZ(ctx, q, []string{in.GoodID})
		}
		return nil, nil
	})
}

// UnbindBarcode применяет отвязку ШК под ключом идемпотентности.
func (r *OperationsRepository) UnbindBarcode(ctx context.Context, operationID, barcode string) (Applied, error) {
	return r.inTx(ctx, operationID, KindUnbindBarcode, func(q Querier) (json.RawMessage, error) {
		return nil, unbindBarcode(ctx, q, barcode)
	})
}

// StockEntryStart открывает сессию ввода остатков по идентификатору устройства.
// Результат - {"session_id": …}: повтор получит тот же id, что и первая попытка.
func (r *OperationsRepository) StockEntryStart(ctx context.Context, operationID, sessionID, warehouseID, createdBy string) (Applied, error) {
	return r.inTx(ctx, operationID, KindStockEntryStart, func(q Querier) (json.RawMessage, error) {
		id, err := createSessionWithID(ctx, q, sessionID, warehouseID, createdBy)
		if err != nil {
			return nil, err
		}
		return jsonResult(map[string]string{"session_id": id})
	})
}

// StockEntryCheckpoint фиксирует ячейку сессии: новые привязки ШК + содержимое ячейки, всё под
// одной пометкой - тем же checkpointCell, что и прямая ручка.
func (r *OperationsRepository) StockEntryCheckpoint(ctx context.Context, operationID, sessionID string, in StockEntryCellInput) (Applied, error) {
	return r.inTx(ctx, operationID, KindStockEntryCheckpoint, func(q Querier) (json.RawMessage, error) {
		if err := checkpointCell(ctx, q, sessionID, in); err != nil {
			return nil, err
		}
		return jsonResult(map[string]int{"accepted": len(in.Lines)})
	})
}

// StockEntryFinalize переносит сессию в остатки и закрывает её.
//
// Ради этой операции журнал и заводился: без него повтор финала упирается в проверку статуса и
// возвращает 409 «сессия уже закрыта» - успешная работа приезжает на устройство отказом и оседает
// на экране разбора. Здесь повтор получает исходное {"written": N}.
func (r *OperationsRepository) StockEntryFinalize(ctx context.Context, operationID, sessionID string) (Applied, error) {
	return r.inTx(ctx, operationID, KindStockEntryFinalize, func(q Querier) (json.RawMessage, error) {
		written, err := finalizeSession(ctx, q, sessionID)
		if err != nil {
			return nil, err
		}
		return jsonResult(map[string]int{"written": written})
	})
}

// ReceiptSubmit применяет приёмку целиком: открывает документ, заводит его ГЕ, кладёт строки
// и оприходует - всё в одной транзакции с пометкой операции.
//
// Зачем одной операцией, а не цепочкой «открыть → строка → … → оприходовать». Очередь
// устройства отклонённую операцию снимает и идёт дальше. Отклонённая строка в цепочке дала бы
// оприходование документа БЕЗ неё - остаток поднялся бы на неполный приход, и узнать об этом
// было бы не из чего. Приёмка приходует целиком или не приходует вовсе; отказ возвращает весь
// документ человеку на разбор.
//
// Повтор безопасен на двух уровнях: журнал операции отдаёт ответ первой попытки, а документ,
// уже оприходованный другим путём, упирается в статус и даёт ErrReceiptPosted.
func (r *OperationsRepository) ReceiptSubmit(ctx context.Context, operationID string, in ReceiptSubmitInput) (Applied, error) {
	applied, err := r.inTx(ctx, operationID, KindReceiptSubmit, func(q Querier) (json.RawMessage, error) {
		if err := createReceipt(ctx, q, in.ReceiptID, in.WarehouseID, in.SupplierID, in.CreatedBy, in.Doc); err != nil {
			return nil, err
		}
		if err := guardReceiptDraft(ctx, q, in.ReceiptID); err != nil {
			return nil, err
		}
		for _, lu := range in.LoadUnits {
			if err := createLoadUnit(ctx, q, lu.ID, lu.Kind); err != nil {
				return nil, err
			}
		}
		// Дефолтную ячейку ищем один раз и только если она нужна: документ, где кладовщик
		// указал ячейку каждой строке, не должен зависеть от её наличия.
		var defaultCell string
		cells := make([]string, len(in.Lines)) // ячейка каждой строки после подстановки - для марок
		for i, ln := range in.Lines {
			if ln.CellID == "" {
				if defaultCell == "" {
					id, err := defaultCellID(ctx, q, in.WarehouseID)
					if errors.Is(err, model.ErrNotFound) {
						return nil, model.ErrNoDefaultCell
					}
					if err != nil {
						return nil, err
					}
					defaultCell = id
				}
				ln.CellID = defaultCell
			}
			cells[i] = ln.CellID
			if err := insertReceiptLine(ctx, q, in.ReceiptID, ln); err != nil {
				return nil, err
			}
		}
		posted, err := postReceipt(ctx, q, in.ReceiptID)
		if err != nil {
			return nil, err
		}
		// Марки ЧЗ - после проводки (CZ-05): месту марки нужен размещённый короб, а проблеме
		// с расхождением - остаток, который она переводит в «Изолятор».
		if err := receiveCZ(ctx, q, receiptCZIntake(in, cells)); err != nil {
			return nil, err
		}
		return jsonResult(map[string]any{"receipt_id": in.ReceiptID, "posted": posted})
	})
	return applied, missingReference(err)
}

// PutawaySubmit проводит сеанс размещения целиком - в одной транзакции с пометкой операции
// (P5-02). Почему одной операцией, а не цепочкой, - та же причина, что у приёмки: отклонённая
// строка в цепочке дала бы проведённый документ «Движение» без неё.
//
// Повтор безопасен на двух уровнях: журнал операции отдаёт ответ первой попытки, а сеанс,
// проведённый другой операцией, упирается в первичный ключ документа и даёт ErrPutawayPosted.
func (r *OperationsRepository) PutawaySubmit(ctx context.Context, operationID string, in PutawaySubmitInput) (Applied, error) {
	applied, err := r.inTx(ctx, operationID, KindPutawaySubmit, func(q Querier) (json.RawMessage, error) {
		placed, err := putawaySubmit(ctx, q, in)
		if err != nil {
			return nil, err
		}
		return jsonResult(map[string]any{"putaway_id": in.PutawayID, "placed": placed})
	})
	return applied, missingReference(err)
}

// MovementSubmit проводит документ движения (перемещение или пополнение) целиком - в одной
// транзакции с пометкой операции (P6-03). Повтор той же операции отдаёт ответ первой попытки;
// тот же документ другой операцией упирается в первичный ключ и даёт ErrMovementPosted.
func (r *OperationsRepository) MovementSubmit(ctx context.Context, operationID string, in MovementSubmitInput) (Applied, error) {
	applied, err := r.inTx(ctx, operationID, KindMovementSubmit, func(q Querier) (json.RawMessage, error) {
		lines, err := movementSubmit(ctx, q, in)
		if err != nil {
			return nil, err
		}
		return jsonResult(map[string]any{"movement_id": in.MovementID, "lines": lines})
	})
	return applied, missingReference(err)
}

// ProblemSubmit фиксирует проблему склада и переводит остаток на склад назначения - в одной
// транзакции с пометкой операции (P6-07-1).
func (r *OperationsRepository) ProblemSubmit(ctx context.Context, operationID string, in ProblemSubmitInput) (Applied, error) {
	applied, err := r.inTx(ctx, operationID, KindProblemSubmit, func(q Querier) (json.RawMessage, error) {
		if err := problemSubmit(ctx, q, in); err != nil {
			return nil, err
		}
		return jsonResult(map[string]any{"problem_id": in.ProblemID})
	})
	return applied, missingReference(err)
}

// ReturnSubmit проводит сеанс отгрузки возврата поставщику целиком - в одной транзакции
// с пометкой операции (ADHOC-31).
func (r *OperationsRepository) ReturnSubmit(ctx context.Context, operationID string, in ReturnSubmitInput) (Applied, error) {
	applied, err := r.inTx(ctx, operationID, KindReturnSubmit, func(q Querier) (json.RawMessage, error) {
		shipped, err := returnSubmit(ctx, q, in)
		if err != nil {
			return nil, err
		}
		return jsonResult(map[string]any{"shipment_id": in.ShipmentID, "shipped": shipped})
	})
	return applied, missingReference(err)
}

// missingReference переводит нарушение внешнего ключа в ErrUnknownReference.
//
// Без перевода оно считалось бы временной неудачей, и очередь устройства повторяла бы
// неисполнимую приёмку вечно, застряв на ней вместе со всеми операциями после неё.
func missingReference(err error) error {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23503" {
		return model.ErrUnknownReference
	}
	return err
}

// inTx - общая обвязка: транзакция, в которой лежат пометка операции и её эффект.
// Вынесена, чтобы у всех типов операций был буквально один и тот же порядок действий.
func (r *OperationsRepository) inTx(ctx context.Context, operationID, kind string, effect func(Querier) (json.RawMessage, error)) (Applied, error) {
	var out Applied
	err := WithinTx(ctx, r.pool, func(q Querier) error {
		var err error
		out, err = once(ctx, q, operationID, kind, func() (json.RawMessage, error) { return effect(q) })
		return err
	})
	if err != nil {
		return Applied{}, err
	}
	return out, nil
}

// jsonResult сворачивает ответ операции в JSON для журнала.
func jsonResult(v any) (json.RawMessage, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return nil, fmt.Errorf("marshal operation result: %w", err)
	}
	return b, nil
}
