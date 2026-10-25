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
)

// Ошибки отгрузки возврата поставщику (ADHOC-31). Все — отказ по существу.
var (
	// ErrShipmentPosted — сеанс отгрузки с этим идентификатором уже проведён.
	ErrShipmentPosted = errors.New("return shipment already posted")
	// ErrEmptyShipment — в сеансе нет ни одной позиции.
	ErrEmptyShipment = errors.New("return shipment has no positions")
)

// ReturnSubmitInput — сеанс отгрузки возврата, собранный устройством (ADHOC-31): какие позиции
// задания (проблемы, решённые возвратом) отгружены. Позиция — только целиком, поэтому
// количество и ячейку устройство не шлёт: сервер снимает с остатка всю позицию там, где она
// лежит, и пишет откуда.
type ReturnSubmitInput struct {
	ShipmentID  string
	TaskID      string
	WarehouseID string
	CreatedBy   string
	ProblemIDs  []string
	// Marks — КИ марок ЧЗ, отсканированных в сеансе (CZ-06, долг 30): позиция россыпью с
	// марками отгружается, только когда отсканированы все её марки.
	Marks []string
}

// returnSubmit проводит сеанс отгрузки возврата целиком (ADHOC-31).
//
// Что: каждая позиция снимается с остатка склада возврата — короб с составом в своей ячейке,
//
//	россыпь там, где лежит (сначала там, куда её положило решение, дальше по адресам);
//	позиция помечается отгруженной, строки сеанса пишут откуда что ушло.
//
// Зачем одной транзакцией: сеанс — один факт отгрузки; отгруженная позиция с остатком на
// складе (или наоборот) разошлась бы с тем, что уехало к поставщику.
//
// Как: задание блокируется (два сеанса одного задания не отгрузят позицию дважды), позиции —
// строками проблем по порядку идентификаторов; остаток меняется примитивами removeStock
// и takeFromLoadUnit — той же точкой, что списание по решению офиса.
func returnSubmit(ctx context.Context, q Querier, in ReturnSubmitInput) (int, error) {
	ids := slices.Clone(in.ProblemIDs)
	slices.Sort(ids)
	ids = slices.Compact(ids)
	if len(ids) == 0 {
		return 0, ErrEmptyShipment
	}
	if err := lockTaskForReturn(ctx, q, in.TaskID, in.WarehouseID); err != nil {
		return 0, err
	}
	if _, err := q.Exec(ctx, `
		INSERT INTO supplier_return_shipments (id, task_id, warehouse_id, created_by)
		VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid)`,
		in.ShipmentID, in.TaskID, in.WarehouseID, in.CreatedBy); err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return 0, ErrShipmentPosted
		}
		return 0, fmt.Errorf("записать сеанс отгрузки: %w", err)
	}

	lineNo := 0
	scanned := newReturnMarks(in.Marks)
	for _, id := range ids {
		p, err := lockReturnPosition(ctx, q, id, in.TaskID)
		if err != nil {
			return 0, err
		}
		if err := scanned.take(ctx, q, p); err != nil {
			return 0, err
		}
		lines, err := problemLines(ctx, q, p)
		if err != nil {
			return 0, err
		}
		if err := writeOffProblem(ctx, q, p, lines, model.CZMarkReturned); err != nil {
			return 0, err
		}
		for _, l := range lines {
			lineNo++
			if _, err := q.Exec(ctx, `
				INSERT INTO supplier_return_shipment_lines
					(shipment_id, line_no, problem_id, cell_id, load_unit_id, good_id, batch_id, qty)
				VALUES ($1::uuid, $2, $3::uuid, $4::uuid, NULLIF($5, '')::uuid, $6::uuid, $7::uuid, $8::numeric)`,
				in.ShipmentID, lineNo, id, l.cell, l.loadUnit, l.good, l.batch, l.qty.String()); err != nil {
				return 0, fmt.Errorf("записать строку отгрузки: %w", err)
			}
		}
		if _, err := q.Exec(ctx, `UPDATE warehouse_problems SET shipment_id = $2::uuid WHERE id = $1::uuid`,
			id, in.ShipmentID); err != nil {
			return 0, fmt.Errorf("отметить позицию отгруженной: %w", err)
		}
	}

	if err := scanned.allTaken(); err != nil {
		return 0, err
	}

	if _, err := q.Exec(ctx, `
		INSERT INTO task_events (task_id, event, user_id, shipment_id)
		VALUES ($1::uuid, $2, $3::uuid, $4::uuid)`,
		in.TaskID, model.TaskEventSession, in.CreatedBy, in.ShipmentID); err != nil {
		return 0, fmt.Errorf("журнал задания: %w", err)
	}
	return len(ids), settleReturnTask(ctx, q, in.TaskID, in.CreatedBy)
}

// lockTaskForReturn блокирует задание возврата и проверяет, что сеанс ему подходит. Кто держит
// задание, не проверяется — как у размещения: сеанс уже сделанная физическая работа.
func lockTaskForReturn(ctx context.Context, q Querier, taskID, warehouseID string) error {
	var kind, status, wh string
	err := q.QueryRow(ctx, `
		SELECT kind, status, warehouse_id::text FROM warehouse_tasks
		WHERE id = $1::uuid FOR UPDATE`, taskID).Scan(&kind, &status, &wh)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrTaskNotFound
	}
	if err != nil {
		return fmt.Errorf("заблокировать задание: %w", err)
	}
	if status == model.TaskDone {
		return ErrTaskDone
	}
	if kind != model.TaskSupplierReturn || wh != warehouseID {
		return ErrTaskMismatch
	}
	return nil
}

// lockReturnPosition блокирует позицию задания возврата — проблему, решённую возвратом в это
// задание и ещё не отгруженную, — и готовит её для снятия с остатка: склад-метка — склад
// возврата, место по умолчанию — первая ячейка, куда товар положило решение.
func lockReturnPosition(ctx context.Context, q Querier, problemID, taskID string) (lockedProblem, error) {
	var p lockedProblem
	var lu, good, batch, qty *string
	var task, shipment *string
	err := q.QueryRow(ctx, `
		SELECT p.warehouse_id::text,
		       COALESCE((SELECT l.cell_id::text FROM warehouse_problem_lines l
		                 WHERE l.problem_id = p.id ORDER BY l.line_no LIMIT 1), p.cell_id::text),
		       p.load_unit_id::text, p.good_id::text, p.batch_id::text, p.qty::text,
		       w.id::text, p.return_task_id::text, p.shipment_id::text
		FROM warehouse_problems p
		JOIN internal_warehouses w ON w.system_role = $2
		WHERE p.id = $1::uuid
		FOR UPDATE OF p`, problemID, model.InternalWarehouseRoleSupplierReturn).
		Scan(&p.warehouse, &p.cell, &lu, &good, &batch, &qty, &p.toIwh, &task, &shipment)
	if errors.Is(err, pgx.ErrNoRows) {
		return lockedProblem{}, ErrNotInTask
	}
	if err != nil {
		return lockedProblem{}, fmt.Errorf("прочитать позицию возврата: %w", err)
	}
	if task == nil || *task != taskID || shipment != nil {
		return lockedProblem{}, ErrNotInTask
	}
	p.id = problemID
	p.loadUnit, p.good, p.batch = deref(lu), deref(good), deref(batch)
	if qty != nil {
		if p.qty, err = decimal.NewFromString(*qty); err != nil {
			return lockedProblem{}, fmt.Errorf("количество позиции: %w", err)
		}
	}
	return p, nil
}

// settleReturnTask переводит задание после сеанса: всё отгружено — выполнено; осталось (офис
// добавил возврат, пока шёл сеанс) — снова в пул без исполнителя, как у размещения.
func settleReturnTask(ctx context.Context, q Querier, taskID, userID string) error {
	var left bool
	if err := q.QueryRow(ctx, `
		SELECT EXISTS (SELECT 1 FROM warehouse_problems
		               WHERE return_task_id = $1::uuid AND shipment_id IS NULL)`,
		taskID).Scan(&left); err != nil {
		return fmt.Errorf("остаток задания возврата: %w", err)
	}
	var err error
	if !left {
		_, err = q.Exec(ctx, `
			UPDATE warehouse_tasks
			SET status = 'done', assignee_id = NULL, completed_by = $2::uuid,
			    completed_at = now(), last_activity_at = now()
			WHERE id = $1::uuid`, taskID, userID)
		if err == nil {
			err = addTaskEvent(ctx, q, taskID, model.TaskEventCompleted, userID, "", "")
		}
	} else {
		_, err = q.Exec(ctx, `
			UPDATE warehouse_tasks
			SET status = 'new', assignee_id = NULL, taken_at = NULL, last_activity_at = now()
			WHERE id = $1::uuid`, taskID)
	}
	if err != nil {
		return fmt.Errorf("перевести задание после отгрузки: %w", err)
	}
	return nil
}
