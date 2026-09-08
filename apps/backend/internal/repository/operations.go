package repository

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"
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
)

// OperationsRepository — применение операций очереди устройства под ключом идемпотентности.
//
// Что: на каждую операцию — своя транзакция, в которой лежат и эффект, и пометка в журнале.
// Зачем: повтор операции не должен применять эффект второй раз (P2-05), а пометка без эффекта
//
//	(или наоборот) вернула бы ту же беду при падении между ними.
//
// Как: WithinTx { once(operation_id) { эффект } } — эффект выполняется через те же
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
		return nil, bindBarcode(ctx, q, in.GoodID, in.Barcode, in.Symbology)
	})
}

// UnbindBarcode применяет отвязку ШК под ключом идемпотентности.
func (r *OperationsRepository) UnbindBarcode(ctx context.Context, operationID, barcode string) (Applied, error) {
	return r.inTx(ctx, operationID, KindUnbindBarcode, func(q Querier) (json.RawMessage, error) {
		return nil, unbindBarcode(ctx, q, barcode)
	})
}

// StockEntryStart открывает сессию ввода остатков по идентификатору устройства.
// Результат — {"session_id": …}: повтор получит тот же id, что и первая попытка.
func (r *OperationsRepository) StockEntryStart(ctx context.Context, operationID, sessionID, warehouseID, createdBy string) (Applied, error) {
	return r.inTx(ctx, operationID, KindStockEntryStart, func(q Querier) (json.RawMessage, error) {
		id, err := createSessionWithID(ctx, q, sessionID, warehouseID, createdBy)
		if err != nil {
			return nil, err
		}
		return jsonResult(map[string]string{"session_id": id})
	})
}

// StockEntryCheckpoint фиксирует ячейку сессии: новые привязки ШК + строки, всё под одной пометкой.
func (r *OperationsRepository) StockEntryCheckpoint(ctx context.Context, operationID, sessionID, cellID string, lines []StockEntryLineInput, barcodes []BarcodeBindInput) (Applied, error) {
	return r.inTx(ctx, operationID, KindStockEntryCheckpoint, func(q Querier) (json.RawMessage, error) {
		if err := guardSessionDraft(ctx, q, sessionID); err != nil {
			return nil, err
		}
		// Привязки — до строк: строка может ссылаться на товар только что привязанного ШК.
		for _, b := range barcodes {
			if err := bindBarcode(ctx, q, b.GoodID, b.Barcode, b.Symbology); err != nil {
				return nil, err
			}
		}
		for _, ln := range lines {
			if err := upsertSessionLine(ctx, q, sessionID, cellID, ln.GoodID, ln.ProductionDate, ln.Qty); err != nil {
				return nil, err
			}
		}
		return jsonResult(map[string]int{"accepted": len(lines)})
	})
}

// StockEntryFinalize переносит сессию в остатки и закрывает её.
//
// Ради этой операции журнал и заводился: без него повтор финала упирается в проверку статуса и
// возвращает 409 «сессия уже закрыта» — успешная работа приезжает на устройство отказом и оседает
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

// inTx — общая обвязка: транзакция, в которой лежат пометка операции и её эффект.
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
