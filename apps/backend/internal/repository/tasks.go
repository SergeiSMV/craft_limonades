package repository

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
)

// Ошибки заданий для склада (P5-02-1).
var (
	// ErrTaskNotFound — задания нет.
	ErrTaskNotFound = errors.New("task not found")
	// ErrTaskTaken — задание держит другой исполнитель, и оно не зависло.
	ErrTaskTaken = errors.New("task is taken by another user")
	// ErrTaskDone — задание уже выполнено.
	ErrTaskDone = errors.New("task is already done")
	// ErrTaskMismatch — сеанс не подходит заданию: другой вид или другой склад.
	ErrTaskMismatch = errors.New("putaway does not match the task")
	// ErrNotInTask — строка сеанса размещает то, чего нет в задании (или уже размещено им).
	ErrNotInTask = errors.New("putaway line is not part of the task")
	// ErrExceedsTask — россыпи размещают больше, чем осталось по заданию.
	ErrExceedsTask = errors.New("putaway line exceeds the task remainder")
)

// createPutawayTaskForReceipt заводит задание на размещение по оприходованной приёмке.
//
// Что: позиции задания — то, что приёмка положила в ячейку приёмки склада: короба (каждый
// одной позицией, сколько бы строк у него ни было) и россыпь по товару и партии.
// Зачем: товар попадает в зону приёмки только с приёмкой, и задание делает её хвост видимым —
// неразмещённая приёмка не потеряется (решение 2026-10-07).
// Как: в транзакции оприходования; приёмка, всё положившая сразу в ячейки хранения, задания
// не создаёт — размещать нечего.
func createPutawayTaskForReceipt(ctx context.Context, q Querier, receiptID string) error {
	rows, err := q.Query(ctx, `
		SELECT rl.load_unit_id::text, rl.good_id::text, rl.batch_id::text, rl.qty::text
		FROM receipt_lines rl
		JOIN cells c ON c.id = rl.cell_id AND c.is_default
		WHERE rl.receipt_id = $1::uuid
		ORDER BY rl.load_unit_id NULLS LAST, rl.good_id, rl.batch_id`, receiptID)
	if err != nil {
		return fmt.Errorf("прочитать строки приёмки для задания: %w", err)
	}
	type src struct {
		lu               *string
		good, batch, qty string
	}
	var lines []src
	for rows.Next() {
		var s src
		if err := rows.Scan(&s.lu, &s.good, &s.batch, &s.qty); err != nil {
			rows.Close()
			return fmt.Errorf("разобрать строку приёмки: %w", err)
		}
		lines = append(lines, s)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return fmt.Errorf("прочитать строки приёмки для задания: %w", err)
	}
	if len(lines) == 0 {
		return nil
	}

	var taskID string
	if err := q.QueryRow(ctx, `
		INSERT INTO warehouse_tasks (kind, warehouse_id, receipt_id)
		SELECT 'putaway', warehouse_id, id FROM receipts WHERE id = $1::uuid
		RETURNING id::text`, receiptID).Scan(&taskID); err != nil {
		return fmt.Errorf("создать задание на размещение: %w", err)
	}
	// Автора нет: задание заводит система по оприходованной приёмке.
	if err := addTaskEvent(ctx, q, taskID, model.TaskEventCreated, "", "", ""); err != nil {
		return err
	}

	lineNo := 0
	seenBox := map[string]bool{}
	for _, s := range lines {
		if s.lu != nil {
			if seenBox[*s.lu] {
				continue
			}
			seenBox[*s.lu] = true
			lineNo++
			_, err = q.Exec(ctx, `
				INSERT INTO putaway_task_items (task_id, line_no, load_unit_id)
				VALUES ($1::uuid, $2, $3::uuid)`, taskID, lineNo, *s.lu)
		} else {
			lineNo++
			_, err = q.Exec(ctx, `
				INSERT INTO putaway_task_items (task_id, line_no, good_id, batch_id, qty)
				VALUES ($1::uuid, $2, $3::uuid, $4::uuid, $5::numeric)`, taskID, lineNo, s.good, s.batch, s.qty)
		}
		if err != nil {
			return fmt.Errorf("позиция задания на размещение: %w", err)
		}
	}
	return nil
}

// taskRemainder — что ещё осталось разместить по заданию: короба и россыпь по (товар, партия).
type taskRemainder struct {
	boxes map[string]bool               // короб задания → ещё не размещён
	loose map[[2]string]decimal.Decimal // (товар, партия) → сколько ещё разместить
}

// done — по заданию всё размещено.
func (r taskRemainder) done() bool {
	for _, open := range r.boxes {
		if open {
			return false
		}
	}
	for _, q := range r.loose {
		if q.IsPositive() {
			return false
		}
	}
	return true
}

// loadTaskRemainder считает остаток задания по проведённым сеансам размещения.
func loadTaskRemainder(ctx context.Context, q Querier, taskID string) (taskRemainder, error) {
	rows, err := q.Query(ctx, `
		SELECT i.load_unit_id::text, i.good_id::text, i.batch_id::text,
		       NOT EXISTS (
		           SELECT 1 FROM putaway_lines pl JOIN putaways p ON p.id = pl.putaway_id
		           WHERE p.task_id = i.task_id AND pl.load_unit_id = i.load_unit_id),
		       (i.qty - COALESCE((
		           SELECT sum(pl.qty) FROM putaway_lines pl JOIN putaways p ON p.id = pl.putaway_id
		           WHERE p.task_id = i.task_id AND pl.good_id = i.good_id AND pl.batch_id = i.batch_id), 0))::text
		FROM putaway_task_items i
		WHERE i.task_id = $1::uuid`, taskID)
	if err != nil {
		return taskRemainder{}, fmt.Errorf("посчитать остаток задания: %w", err)
	}
	defer rows.Close()
	rem := taskRemainder{boxes: map[string]bool{}, loose: map[[2]string]decimal.Decimal{}}
	for rows.Next() {
		var lu, good, batch, left *string
		var open bool
		if err := rows.Scan(&lu, &good, &batch, &open, &left); err != nil {
			return taskRemainder{}, fmt.Errorf("разобрать остаток задания: %w", err)
		}
		if lu != nil {
			rem.boxes[*lu] = open
			continue
		}
		qty, err := decimal.NewFromString(*left)
		if err != nil {
			return taskRemainder{}, fmt.Errorf("остаток россыпи задания: %w", err)
		}
		rem.loose[[2]string{*good, *batch}] = qty
	}
	return rem, rows.Err()
}

// lockTaskForPutaway блокирует задание сеанса и проверяет, что сеанс ему подходит.
//
// Блокировка нужна потому, что остаток задания считается по сеансам: два сеанса одного
// задания одновременно (взятое и зависшее, затем взятое другим) иначе разместили бы одну
// и ту же россыпь дважды. Кто держит задание, не проверяется: сеанс — это уже сделанная
// физическая работа, и отказ из-за смены исполнителя оставил бы товар перенесённым на деле
// и неперенесённым в учёте.
func lockTaskForPutaway(ctx context.Context, q Querier, taskID, warehouseID string) error {
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
	if kind != model.TaskPutaway || wh != warehouseID {
		return ErrTaskMismatch
	}
	return nil
}

// settleTaskAfterPutaway переводит задание после проведённого сеанса.
//
// Всё размещено — задание выполнено. Иначе оно возвращается в пул «новым» без исполнителя:
// частичное «Завершить» отдаёт остаток любому (решение 2026-10-07), — кладовщик мог закончить
// смену, и остаток не должен застрять за ним.
func settleTaskAfterPutaway(ctx context.Context, q Querier, taskID, userID string) error {
	rem, err := loadTaskRemainder(ctx, q, taskID)
	if err != nil {
		return err
	}
	if rem.done() {
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
		return fmt.Errorf("перевести задание после размещения: %w", err)
	}
	return nil
}

// TaskRepository — задания для склада: пул, взятие, лента завершённых (P5-02-1).
type TaskRepository struct {
	pool *pgxpool.Pool
}

// NewTaskRepository создаёт репозиторий заданий.
func NewTaskRepository(pool *pgxpool.Pool) *TaskRepository {
	return &TaskRepository{pool: pool}
}

// visibleSQL — условие «задание видно этому пользователю в текущих»: в пуле, взято им самим
// или зависло у другого. $1 — пользователь, $2 — срок, после которого взятое считается зависшим.
const visibleSQL = `t.status <> 'done' AND (
	t.status = 'new' OR t.assignee_id = $1::uuid
	OR t.last_activity_at < now() - $2::interval)`

// taskHeaderSQL — шапка задания с основанием и исполнителем; статус — как его видит $1.
const taskHeaderSQL = `
	SELECT t.id::text, t.number, t.kind,
	       CASE WHEN t.status = 'in_progress' AND t.assignee_id = $1::uuid THEN 'in_progress'
	            WHEN t.status = 'in_progress' THEN 'new'
	            ELSE t.status END,
	       t.warehouse_id::text, t.receipt_id::text, COALESCE(s.name, ''), r.posted_at,
	       CASE WHEN t.assignee_id = $1::uuid THEN t.assignee_id::text END,
	       CASE WHEN t.assignee_id = $1::uuid THEN COALESCE(u.full_name, '') ELSE '' END,
	       CASE WHEN t.assignee_id = $1::uuid THEN t.taken_at END,
	       t.created_at
	FROM warehouse_tasks t
	LEFT JOIN receipts r  ON r.id = t.receipt_id
	LEFT JOIN suppliers s ON s.id = r.supplier_id
	LEFT JOIN users u     ON u.id = t.assignee_id`

// Current возвращает текущие задания, видимые пользователю, — пул и свои взятые, с позициями.
// Старые сверху: задание, ждущее дольше, важнее разобрать раньше.
func (r *TaskRepository) Current(ctx context.Context, userID string, staleAfter time.Duration) ([]model.Task, error) {
	rows, err := r.pool.Query(ctx, taskHeaderSQL+`
		WHERE `+visibleSQL+`
		ORDER BY t.created_at, t.number`, userID, intervalOf(staleAfter))
	if err != nil {
		return nil, fmt.Errorf("текущие задания: %w", err)
	}
	tasks, err := scanTasks(rows)
	if err != nil {
		return nil, err
	}
	if err := r.attachItems(ctx, tasks); err != nil {
		return nil, err
	}
	return tasks, nil
}

// ByID возвращает задание с позициями — в том виде, в каком его видит пользователь.
func (r *TaskRepository) ByID(ctx context.Context, id, userID string) (model.Task, error) {
	rows, err := r.pool.Query(ctx, taskHeaderSQL+` WHERE t.id = $2::uuid`, userID, id)
	if err != nil {
		return model.Task{}, fmt.Errorf("задание: %w", err)
	}
	tasks, err := scanTasks(rows)
	if err != nil {
		return model.Task{}, err
	}
	if len(tasks) == 0 {
		return model.Task{}, ErrTaskNotFound
	}
	if err := r.attachItems(ctx, tasks); err != nil {
		return model.Task{}, err
	}
	return tasks[0], nil
}

func scanTasks(rows pgx.Rows) ([]model.Task, error) {
	defer rows.Close()
	out := []model.Task{}
	for rows.Next() {
		var t model.Task
		if err := rows.Scan(&t.ID, &t.Number, &t.Kind, &t.Status, &t.WarehouseID, &t.ReceiptID,
			&t.SupplierName, &t.ReceivedAt, &t.AssigneeID, &t.AssigneeName, &t.TakenAt, &t.CreatedAt); err != nil {
			return nil, fmt.Errorf("разобрать задание: %w", err)
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// attachItems дочитывает позиции заданий с остатком и составом коробов — двумя запросами
// на весь список, а не по запросу на задание.
func (r *TaskRepository) attachItems(ctx context.Context, tasks []model.Task) error {
	if len(tasks) == 0 {
		return nil
	}
	ids := make([]string, len(tasks))
	index := map[string]int{}
	for i, t := range tasks {
		ids[i] = t.ID
		index[t.ID] = i
	}
	rows, err := r.pool.Query(ctx, `
		SELECT i.task_id::text, i.line_no, i.load_unit_id::text,
		       NOT EXISTS (
		           SELECT 1 FROM putaway_lines pl JOIN putaways p ON p.id = pl.putaway_id
		           WHERE p.task_id = i.task_id AND pl.load_unit_id = i.load_unit_id),
		       g.id::text, g.code, g.name, g.uom, i.batch_id::text, b.production_date,
		       COALESCE(i.qty, 0)::text,
		       (COALESCE(i.qty, 0) - COALESCE((
		           SELECT sum(pl.qty) FROM putaway_lines pl JOIN putaways p ON p.id = pl.putaway_id
		           WHERE p.task_id = i.task_id AND pl.good_id = i.good_id AND pl.batch_id = i.batch_id), 0))::text
		FROM putaway_task_items i
		LEFT JOIN goods g   ON g.id = i.good_id
		LEFT JOIN batches b ON b.id = i.batch_id
		WHERE i.task_id = ANY($1::uuid[])
		ORDER BY i.task_id, i.line_no`, ids)
	if err != nil {
		return fmt.Errorf("позиции заданий: %w", err)
	}
	var boxIDs []string
	for rows.Next() {
		var taskID, qty, left string
		var it model.PutawayTaskItem
		var open bool
		var gid, gcode, gname, guom *string
		if err := rows.Scan(&taskID, &it.LineNo, &it.LoadUnitID, &open, &gid, &gcode, &gname, &guom,
			&it.BatchID, &it.ProductionDate, &qty, &left); err != nil {
			rows.Close()
			return fmt.Errorf("разобрать позицию задания: %w", err)
		}
		if it.LoadUnitID != nil {
			it.Placed = !open
			boxIDs = append(boxIDs, *it.LoadUnitID)
		} else {
			it.Good = &model.TaskGood{ID: *gid, Code: deref(gcode), Name: deref(gname), Uom: deref(guom)}
			it.Qty, _ = decimal.NewFromString(qty)
			it.Remaining, _ = decimal.NewFromString(left)
			it.Placed = !it.Remaining.IsPositive()
		}
		t := &tasks[index[taskID]]
		t.Items = append(t.Items, it)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return fmt.Errorf("позиции заданий: %w", err)
	}
	if len(boxIDs) == 0 {
		return nil
	}

	contents, err := r.boxContents(ctx, boxIDs)
	if err != nil {
		return err
	}
	for ti := range tasks {
		for ii := range tasks[ti].Items {
			if lu := tasks[ti].Items[ii].LoadUnitID; lu != nil {
				tasks[ti].Items[ii].Contents = contents[*lu]
			}
		}
	}
	return nil
}

// boxContents — состав коробов с товаром и датой партии.
func (r *TaskRepository) boxContents(ctx context.Context, ids []string) (map[string][]model.TaskGoodQty, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT c.load_unit_id::text, g.id::text, g.code, g.name, g.uom, b.production_date, c.qty::text
		FROM lu_content c
		JOIN goods g   ON g.id = c.good_id
		JOIN batches b ON b.id = c.batch_id
		WHERE c.load_unit_id = ANY($1::uuid[]) AND c.qty > 0
		ORDER BY g.name, b.production_date`, ids)
	if err != nil {
		return nil, fmt.Errorf("состав коробов задания: %w", err)
	}
	defer rows.Close()
	out := map[string][]model.TaskGoodQty{}
	for rows.Next() {
		var lu, qty string
		var c model.TaskGoodQty
		var code *string
		if err := rows.Scan(&lu, &c.Good.ID, &code, &c.Good.Name, &c.Good.Uom, &c.ProductionDate, &qty); err != nil {
			return nil, fmt.Errorf("разобрать состав короба: %w", err)
		}
		c.Good.Code = deref(code)
		c.Qty, _ = decimal.NewFromString(qty)
		out[lu] = append(out[lu], c)
	}
	return out, rows.Err()
}

// Take отдаёт задание пользователю: из пула, своё повторно или зависшее у другого.
//
// Повтор своим исполнителем — не ошибка и не событие: кладовщик нажал «Взять» дважды или
// ответ не дошёл. Взятие из пула пишется в журнал как taken, перехват зависшего — как
// intercepted с тем, у кого перехватили. Строка задания блокируется, чтобы двое, одновременно
// взявшие задание, не записали оба своё взятие.
func (r *TaskRepository) Take(ctx context.Context, id, userID string, staleAfter time.Duration) error {
	return WithinTx(ctx, r.pool, func(q Querier) error {
		var status string
		var holder *string
		var stale bool
		err := q.QueryRow(ctx, `
			SELECT status, assignee_id::text,
			       COALESCE(last_activity_at < now() - $2::interval, false)
			FROM warehouse_tasks WHERE id = $1::uuid FOR UPDATE`, id, intervalOf(staleAfter)).
			Scan(&status, &holder, &stale)
		switch {
		case errors.Is(err, pgx.ErrNoRows):
			return ErrTaskNotFound
		case err != nil:
			return fmt.Errorf("взять задание: %w", err)
		case status == model.TaskDone:
			return ErrTaskDone
		}

		event, prev := model.TaskEventTaken, ""
		if status == model.TaskInProgress {
			switch {
			case holder != nil && *holder == userID:
				return nil
			case !stale:
				return ErrTaskTaken
			}
			event, prev = model.TaskEventIntercepted, deref(holder)
		}
		if _, err := q.Exec(ctx, `
			UPDATE warehouse_tasks
			SET status = 'in_progress', assignee_id = $2::uuid, taken_at = now(), last_activity_at = now()
			WHERE id = $1::uuid`, id, userID); err != nil {
			return fmt.Errorf("взять задание: %w", err)
		}
		return addTaskEvent(ctx, q, id, event, userID, prev, "")
	})
}

// Release возвращает своё взятое задание в пул. Задание уже в пуле — не ошибка (повтор).
func (r *TaskRepository) Release(ctx context.Context, id, userID string) error {
	var released bool
	err := WithinTx(ctx, r.pool, func(q Querier) error {
		tag, err := q.Exec(ctx, `
			UPDATE warehouse_tasks
			SET status = 'new', assignee_id = NULL, taken_at = NULL
			WHERE id = $1::uuid AND status = 'in_progress' AND assignee_id = $2::uuid`, id, userID)
		if err != nil {
			return fmt.Errorf("отказаться от задания: %w", err)
		}
		if tag.RowsAffected() == 0 {
			return nil
		}
		released = true
		return addTaskEvent(ctx, q, id, model.TaskEventReleased, userID, "", "")
	})
	if err != nil || released {
		return err
	}
	var status string
	err = r.pool.QueryRow(ctx, `SELECT status FROM warehouse_tasks WHERE id = $1::uuid`, id).Scan(&status)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return ErrTaskNotFound
	case err != nil:
		return fmt.Errorf("отказаться от задания: %w", err)
	case status == model.TaskNew:
		return nil
	case status == model.TaskDone:
		return ErrTaskDone
	default:
		return ErrTaskTaken
	}
}

// addTaskEvent дописывает событие в журнал задания — в транзакции того, что его вызвало.
// Пустые userID, prevUserID, putawayID — «нет» (системное событие, не перехват, не заход).
func addTaskEvent(ctx context.Context, q Querier, taskID, event, userID, prevUserID, putawayID string) error {
	_, err := q.Exec(ctx, `
		INSERT INTO task_events (task_id, event, user_id, prev_user_id, putaway_id)
		VALUES ($1::uuid, $2, NULLIF($3, '')::uuid, NULLIF($4, '')::uuid, NULLIF($5, '')::uuid)`,
		taskID, event, userID, prevUserID, putawayID)
	if err != nil {
		return fmt.Errorf("журнал задания: %w", err)
	}
	return nil
}

// Events — журнал задания по порядку: что случилось, кто и когда.
func (r *TaskRepository) Events(ctx context.Context, taskID string) ([]model.TaskEvent, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT e.event, COALESCE(u.full_name, ''), COALESCE(pu.full_name, ''), e.putaway_id::text, e.at
		FROM task_events e
		LEFT JOIN users u  ON u.id = e.user_id
		LEFT JOIN users pu ON pu.id = e.prev_user_id
		WHERE e.task_id = $1::uuid
		ORDER BY e.seq`, taskID)
	if err != nil {
		return nil, fmt.Errorf("журнал задания: %w", err)
	}
	defer rows.Close()
	out := []model.TaskEvent{}
	for rows.Next() {
		var ev model.TaskEvent
		if err := rows.Scan(&ev.Event, &ev.UserName, &ev.PrevUserName, &ev.PutawayID, &ev.At); err != nil {
			return nil, fmt.Errorf("разобрать событие задания: %w", err)
		}
		out = append(out, ev)
	}
	return out, rows.Err()
}

// Completed — страница ленты «Завершённые»: свежие сверху, подгрузка курсором.
func (r *TaskRepository) Completed(ctx context.Context, f model.CompletedTasksFilter) ([]model.CompletedTask, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT t.id::text, t.number, t.kind, COALESCE(s.name, ''), t.completed_at,
		       (SELECT count(*) FROM putaways p WHERE p.task_id = t.id)
		FROM warehouse_tasks t
		LEFT JOIN receipts r  ON r.id = t.receipt_id
		LEFT JOIN suppliers s ON s.id = r.supplier_id
		WHERE t.status = 'done'
		  AND ($1::timestamptz IS NULL OR t.completed_at >= $1)
		  AND ($2::timestamptz IS NULL OR t.completed_at <  $2)
		  AND ($3::text = '' OR t.kind = $3)
		  AND ($4::text = '' OR EXISTS (
		      SELECT 1 FROM putaways p WHERE p.task_id = t.id AND p.created_by = NULLIF($4, '')::uuid))
		  AND ($5::timestamptz IS NULL OR (t.completed_at, t.id) < ($5, NULLIF($6, '')::uuid))
		ORDER BY t.completed_at DESC, t.id DESC
		LIMIT $7`,
		f.From, f.To, f.Kind, f.ExecutorID, f.BeforeCompletedAt, f.BeforeID, f.Limit)
	if err != nil {
		return nil, fmt.Errorf("завершённые задания: %w", err)
	}
	out := []model.CompletedTask{}
	index := map[string]int{}
	for rows.Next() {
		var c model.CompletedTask
		if err := rows.Scan(&c.ID, &c.Number, &c.Kind, &c.SupplierName, &c.CompletedAt, &c.Sessions); err != nil {
			rows.Close()
			return nil, fmt.Errorf("разобрать завершённое задание: %w", err)
		}
		index[c.ID] = len(out)
		out = append(out, c)
	}
	rows.Close()
	if err := rows.Err(); err != nil || len(out) == 0 {
		return out, err
	}

	ids := make([]string, len(out))
	for i, c := range out {
		ids[i] = c.ID
	}
	ex, err := r.pool.Query(ctx, `
		SELECT p.task_id::text, u.id::text, u.full_name
		FROM putaways p JOIN users u ON u.id = p.created_by
		WHERE p.task_id = ANY($1::uuid[])
		GROUP BY p.task_id, u.id, u.full_name
		ORDER BY p.task_id, min(p.posted_at)`, ids)
	if err != nil {
		return nil, fmt.Errorf("исполнители заданий: %w", err)
	}
	defer ex.Close()
	for ex.Next() {
		var taskID string
		var u model.TaskUser
		if err := ex.Scan(&taskID, &u.ID, &u.FullName); err != nil {
			return nil, fmt.Errorf("разобрать исполнителя: %w", err)
		}
		c := &out[index[taskID]]
		c.Executors = append(c.Executors, u)
	}
	return out, ex.Err()
}

// Executors — все, кто когда-либо выполнял задания: варианты фильтра ленты по исполнителю.
func (r *TaskRepository) Executors(ctx context.Context) ([]model.TaskUser, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT DISTINCT u.id::text, u.full_name
		FROM putaways p JOIN users u ON u.id = p.created_by
		ORDER BY u.full_name`)
	if err != nil {
		return nil, fmt.Errorf("исполнители заданий: %w", err)
	}
	defer rows.Close()
	out := []model.TaskUser{}
	for rows.Next() {
		var u model.TaskUser
		if err := rows.Scan(&u.ID, &u.FullName); err != nil {
			return nil, fmt.Errorf("разобрать исполнителя: %w", err)
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

// Sessions — заходы по заданию: проведённые сеансы размещения со строками, по порядку.
func (r *TaskRepository) Sessions(ctx context.Context, taskID string) ([]model.TaskSession, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT p.id::text, u.id::text, u.full_name, p.posted_at,
		       pl.load_unit_id::text, g.id::text, g.code, g.name, g.uom, b.production_date, pl.qty::text,
		       cf.address, ct.address
		FROM putaways p
		JOIN users u          ON u.id = p.created_by
		JOIN putaway_lines pl ON pl.putaway_id = p.id
		JOIN cells cf         ON cf.id = pl.from_cell_id
		JOIN cells ct         ON ct.id = pl.to_cell_id
		LEFT JOIN goods g     ON g.id = pl.good_id
		LEFT JOIN batches b   ON b.id = pl.batch_id
		WHERE p.task_id = $1::uuid
		ORDER BY p.posted_at, p.id, pl.line_no`, taskID)
	if err != nil {
		return nil, fmt.Errorf("заходы по заданию: %w", err)
	}
	defer rows.Close()
	out := []model.TaskSession{}
	for rows.Next() {
		var s model.TaskSession
		var ln model.TaskSessionLine
		var gid, gcode, gname, guom, qty *string
		if err := rows.Scan(&s.PutawayID, &s.User.ID, &s.User.FullName, &s.PostedAt,
			&ln.LoadUnitID, &gid, &gcode, &gname, &guom, &ln.ProductionDate, &qty,
			&ln.FromAddress, &ln.ToAddress); err != nil {
			return nil, fmt.Errorf("разобрать заход: %w", err)
		}
		if gid != nil {
			ln.Good = &model.TaskGood{ID: *gid, Code: deref(gcode), Name: deref(gname), Uom: deref(guom)}
		}
		if qty != nil {
			d, _ := decimal.NewFromString(*qty)
			ln.Qty = &d
		}
		if n := len(out); n > 0 && out[n-1].PutawayID == s.PutawayID {
			out[n-1].Lines = append(out[n-1].Lines, ln)
			continue
		}
		s.Lines = []model.TaskSessionLine{ln}
		out = append(out, s)
	}
	return out, rows.Err()
}

// intervalOf — длительность в виде, который Postgres примет как interval.
func intervalOf(d time.Duration) string {
	return fmt.Sprintf("%d seconds", int64(d.Seconds()))
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}
