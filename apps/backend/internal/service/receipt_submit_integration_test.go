package service_test

import (
	"context"
	"testing"

	"github.com/google/uuid"
	"github.com/shopspring/decimal"

	"craftwms/internal/repository"
	"craftwms/internal/service"
)

// Приёмка из очереди устройства (P4-09): документ, его ГЕ, строки и оприходование - одной
// операцией receipt_submit. Главное свойство - атомарность: отказ любой части не оставляет
// после себя ни документа, ни остатка, ни короба.

// receiptOp собирает операцию receipt_submit для окружения приёмки.
func (e *rcEnv) receiptOp(opID, receiptID string, loadUnits []map[string]any, lines []map[string]any) service.Operation {
	return opWith(opID, repository.KindReceiptSubmit, map[string]any{
		"receipt_id":   receiptID,
		"warehouse_id": e.warehouse,
		"doc_number":   "ТН-1",
		"doc_date":     "01-10-2026",
		"supplier_id":  e.supplier,
		"load_units":   loadUnits,
		"lines":        lines,
	})
}

// applyOne отправляет батч из одной операции и возвращает её исход.
func (e *rcEnv) applyOne(t *testing.T, op service.Operation) service.OperationResult {
	t.Helper()
	res, err := newOperationsSvc(e.pool).Apply(context.Background(), e.user, []service.Operation{op})
	if err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if len(res) != 1 {
		t.Fatalf("ждали один исход, получили %d", len(res))
	}
	return res[0]
}

// countRows - сколько строк в таблице под условием.
func (e *rcEnv) countRows(t *testing.T, sql string, args ...any) int {
	t.Helper()
	var n int
	if err := e.pool.QueryRow(context.Background(), sql, args...).Scan(&n); err != nil {
		t.Fatalf("count %q: %v", sql, err)
	}
	return n
}

// Критерий P4-09 на сервере: обе ветки (короб и россыпь) одной операцией, повтор не удваивает.
func TestReceiptSubmit_bothBranchesAndReplay(t *testing.T) {
	e := setupReceipt(t)
	ctx := context.Background()
	receiptID := uuid.NewString()
	luID := uuid.NewString()
	const opID = "bbbbbbbb-1111-4111-8111-bbbbbbbbbbbb"

	op := e.receiptOp(opID, receiptID,
		[]map[string]any{{"id": luID, "kind": "box"}},
		[]map[string]any{
			// Россыпь без ячейки - ляжет в дефолтную.
			{"good_id": e.good, "production_date": "01-09-2026", "qty": 5},
			// Короб в указанную ячейку.
			{"good_id": e.good, "production_date": "01-09-2026", "cell_id": e.cell1, "load_unit_id": luID, "qty": 12},
		})

	first := e.applyOne(t, op)
	if first.Status != service.StatusAccepted {
		t.Fatalf("ждали accepted, получили %q (%s)", first.Status, first.Error)
	}

	batch := e.batchOf(t, "2026-09-01")
	if got := e.qty(t, e.cellDefault, batch); !got.Equal(decimal.NewFromInt(5)) {
		t.Fatalf("россыпь в дефолтной ячейке: ждали 5, получили %s", got)
	}
	if got := e.qty(t, e.cell1, batch); !got.Equal(decimal.NewFromInt(12)) {
		t.Fatalf("короб в ячейке: ждали 12, получили %s", got)
	}

	rc, lines, err := e.svc.Get(ctx, receiptID)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if rc.Status != "posted" || len(lines) != 2 {
		t.Fatalf("документ: ждали posted и 2 строки, получили %q и %d", rc.Status, len(lines))
	}
	if rc.CreatedBy != e.user {
		t.Fatalf("автор документа - из токена: ждали %s, получили %s", e.user, rc.CreatedBy)
	}
	var luStatus, luCell string
	if err := e.pool.QueryRow(ctx, `SELECT status, cell_id::text FROM load_units WHERE id = $1::uuid`, luID).
		Scan(&luStatus, &luCell); err != nil {
		t.Fatalf("ГЕ: %v", err)
	}
	if luStatus != "placed" || luCell != e.cell1 {
		t.Fatalf("ГЕ: ждали placed в %s, получили %q в %s", e.cell1, luStatus, luCell)
	}

	// Повтор - так очередь ведёт себя после оборванного ответа. Приход не должен удвоиться.
	second := e.applyOne(t, op)
	if second.Status != service.StatusDuplicate {
		t.Fatalf("повтор: ждали duplicate, получили %q (%s)", second.Status, second.Error)
	}
	if got := e.qty(t, e.cell1, batch); !got.Equal(decimal.NewFromInt(12)) {
		t.Fatalf("после повтора: ждали 12, получили %s", got)
	}

	// Тот же документ под НОВЫМ operation_id (например, дубль в очереди) - отказ, а не второй приход.
	third := e.applyOne(t, e.receiptOp("cccccccc-1111-4111-8111-cccccccccccc", receiptID, nil,
		[]map[string]any{{"good_id": e.good, "production_date": "01-09-2026", "qty": 5}}))
	if third.Status != service.StatusRejected {
		t.Fatalf("документ под чужой операцией: ждали rejected, получили %q", third.Status)
	}
	if got := e.qty(t, e.cellDefault, batch); !got.Equal(decimal.NewFromInt(5)) {
		t.Fatalf("после дубля документа: ждали 5, получили %s", got)
	}
}

// Отказ любой строки откатывает всю приёмку: ни документа, ни остатка, ни короба.
// Ради этого приёмка и уходит одной операцией, а не цепочкой.
func TestReceiptSubmit_rejectionIsAtomic(t *testing.T) {
	e := setupReceipt(t)
	receiptID := uuid.NewString()
	luID := uuid.NewString()

	res := e.applyOne(t, e.receiptOp("dddddddd-1111-4111-8111-dddddddddddd", receiptID,
		[]map[string]any{{"id": luID}},
		[]map[string]any{
			{"good_id": e.good, "production_date": "01-09-2026", "load_unit_id": luID, "qty": 3},
			// Товара нет в справочнике: устройство собирало приёмку по устаревшему кэшу.
			{"good_id": uuid.NewString(), "production_date": "01-09-2026", "qty": 1},
		}))
	if res.Status != service.StatusRejected {
		t.Fatalf("ждали rejected, получили %q", res.Status)
	}
	if got := e.countRows(t, `SELECT count(*) FROM receipts WHERE id = $1::uuid`, receiptID); got != 0 {
		t.Fatalf("документ остался после отказа: %d", got)
	}
	if got := e.countRows(t, `SELECT count(*) FROM load_units WHERE id = $1::uuid`, luID); got != 0 {
		t.Fatalf("короб остался после отказа: %d", got)
	}
	if got := e.countRows(t, `SELECT count(*) FROM stock`); got != 0 {
		t.Fatalf("остаток поднялся после отказа: %d строк", got)
	}
	// Пометка операции тоже откатилась: после исправления справочника повтор применится заново.
	if got := e.countRows(t, `SELECT count(*) FROM processed_operations`); got != 0 {
		t.Fatalf("операция помечена применённой, хотя отклонена: %d", got)
	}
}

// Короб в двух ячейках - противоречивый документ: отказ целиком, без частичного прихода.
func TestReceiptSubmit_loadUnitInTwoCellsRejected(t *testing.T) {
	e := setupReceipt(t)
	luID := uuid.NewString()

	res := e.applyOne(t, e.receiptOp("eeeeeeee-1111-4111-8111-eeeeeeeeeeee", uuid.NewString(),
		[]map[string]any{{"id": luID}},
		[]map[string]any{
			{"good_id": e.good, "production_date": "01-09-2026", "cell_id": e.cell1, "load_unit_id": luID, "qty": 1},
			{"good_id": e.good, "production_date": "02-09-2026", "cell_id": e.cell2, "load_unit_id": luID, "qty": 1},
		}))
	if res.Status != service.StatusRejected {
		t.Fatalf("ждали rejected, получили %q", res.Status)
	}
	if got := e.countRows(t, `SELECT count(*) FROM stock`); got != 0 {
		t.Fatalf("частичный приход: %d строк остатка", got)
	}
}
