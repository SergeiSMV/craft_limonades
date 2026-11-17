package repository

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
)

// createPutawayTaskForReceipt заводит задание на размещение по оприходованной приёмке.
//
// Что: позиции задания - то, что приёмка положила в ячейку приёмки склада: короба (каждый
// одной позицией, сколько бы строк у него ни было) и россыпь по товару и партии.
// Зачем: товар попадает в зону приёмки только с приёмкой, и задание делает её хвост видимым -
// неразмещённая приёмка не потеряется (решение 2026-10-07).
// Как: в транзакции оприходования; приёмка, всё положившая сразу в ячейки хранения, задания
// не создаёт - размещать нечего.
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

// createPutawayTaskForProblem заводит задание на размещение по решению «разместить» (ADHOC-55).
//
// Что: позиции - то из товара проблемы, что лежит в ячейке приёмки: короб целиком или россыпь
// по товару и партии. Товар в ячейках хранения задания не требует - он уже на месте.
// Зачем: решение снимает метку на месте, и товар в ячейке приёмки становится «Основным» вне
// задания приёмки; ячейку приёмки разносит только задание (P5-02-1), иначе товар застрянет.
// Как: в транзакции решения после снятия метки; основание - проблема (problem_id). Если в
// ячейке приёмки ничего нет, задания нет.
func createPutawayTaskForProblem(ctx context.Context, q Querier, problemID, warehouseID string, lines []problemLine) error {
	receiving, err := defaultCellID(ctx, q, warehouseID)
	if errors.Is(err, model.ErrNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	var items []problemLine
	seenBox := map[string]bool{}
	for _, l := range lines {
		if l.cell != receiving || (l.loadUnit != "" && seenBox[l.loadUnit]) {
			continue
		}
		if l.loadUnit != "" {
			seenBox[l.loadUnit] = true
		}
		items = append(items, l)
	}
	if len(items) == 0 {
		return nil
	}

	var taskID string
	if err := q.QueryRow(ctx, `
		INSERT INTO warehouse_tasks (kind, warehouse_id, problem_id)
		VALUES ('putaway', $1::uuid, $2::uuid)
		RETURNING id::text`, warehouseID, problemID).Scan(&taskID); err != nil {
		return fmt.Errorf("создать задание на размещение по проблеме: %w", err)
	}
	// Автора нет: задание заводит система по решению офиса.
	if err := addTaskEvent(ctx, q, taskID, model.TaskEventCreated, "", "", ""); err != nil {
		return err
	}
	for i, it := range items {
		if it.loadUnit != "" {
			_, err = q.Exec(ctx, `
				INSERT INTO putaway_task_items (task_id, line_no, load_unit_id)
				VALUES ($1::uuid, $2, $3::uuid)`, taskID, i+1, it.loadUnit)
		} else {
			_, err = q.Exec(ctx, `
				INSERT INTO putaway_task_items (task_id, line_no, good_id, batch_id, qty)
				VALUES ($1::uuid, $2, $3::uuid, $4::uuid, $5::numeric)`, taskID, i+1, it.good, it.batch, it.qty.String())
		}
		if err != nil {
			return fmt.Errorf("позиция задания на размещение по проблеме: %w", err)
		}
	}
	return nil
}

// excludeFromPutawayTask убирает из задания приёмки россыпь, которую проводка тут же увела
// проблемой в «Изолятор» (CZ-05): размещение берёт россыпь только «Основного», и позиция
// с изолированным товаром не закрылась бы никогда. Россыпь вне ячейки приёмки в задание не
// попадала - убирать нечего. Опустевшее задание удаляется: оно только что создано этой же
// проводкой, сеансов по нему нет.
func excludeFromPutawayTask(ctx context.Context, q Querier, receiptID, cellID, goodID, productionDate string, qty decimal.Decimal) error {
	var receiving bool
	if err := q.QueryRow(ctx, `SELECT is_default FROM cells WHERE id = $1::uuid`, cellID).Scan(&receiving); err != nil {
		return fmt.Errorf("ячейка проблемы приёмки: %w", err)
	}
	if !receiving {
		return nil
	}
	batchID, err := existingBatch(ctx, q, goodID, productionDate)
	if err != nil {
		return err
	}
	// Позиция россыпи по товару и партии в задании приёмки одна (строки приёмки уникальны
	// по товару, партии, ячейке и ГЕ): уходит целиком - удаляется, иначе уменьшается.
	const item = `
		FROM warehouse_tasks t
		WHERE t.id = i.task_id AND t.receipt_id = $1::uuid AND i.load_unit_id IS NULL
		  AND i.good_id = $2::uuid AND i.batch_id = $3::uuid`
	tag, err := q.Exec(ctx, `DELETE FROM putaway_task_items i USING warehouse_tasks t
		WHERE t.id = i.task_id AND t.receipt_id = $1::uuid AND i.load_unit_id IS NULL
		  AND i.good_id = $2::uuid AND i.batch_id = $3::uuid AND i.qty <= $4::numeric`,
		receiptID, goodID, batchID, qty.String())
	if err != nil {
		return fmt.Errorf("убрать позицию из задания: %w", err)
	}
	if tag.RowsAffected() == 0 {
		if _, err := q.Exec(ctx, `UPDATE putaway_task_items i SET qty = i.qty - $4::numeric`+item,
			receiptID, goodID, batchID, qty.String()); err != nil {
			return fmt.Errorf("уменьшить позицию задания: %w", err)
		}
		return nil
	}
	if _, err := q.Exec(ctx, `
		DELETE FROM warehouse_tasks t
		WHERE t.receipt_id = $1::uuid
		  AND NOT EXISTS (SELECT 1 FROM putaway_task_items i WHERE i.task_id = t.id)`, receiptID); err != nil {
		return fmt.Errorf("удалить пустое задание: %w", err)
	}
	return nil
}

// taskRemainder - что ещё осталось разместить по заданию: короба и россыпь по (товар, партия).
type taskRemainder struct {
	boxes map[string]bool               // короб задания → ещё не размещён
	loose map[[2]string]decimal.Decimal // (товар, партия) → сколько ещё разместить
}

// snapshot запоминает остаток задания и возвращает функцию, которая его восстановит
// (ADHOC-40): отклонённая строка размещения не должна уменьшать остаток для следующих.
// Копия целиком - позиций в задании единицы, а строка может задеть и короб, и партию.
func (r taskRemainder) snapshot() (restore func()) {
	boxes := maps.Clone(r.boxes)
	loose := maps.Clone(r.loose)
	return func() {
		maps.Copy(r.boxes, boxes)
		maps.Copy(r.loose, loose)
	}
}

// done - по заданию всё размещено.
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
// и ту же россыпь дважды. Кто держит задание, не проверяется: сеанс - это уже сделанная
// физическая работа, и отказ из-за смены исполнителя оставил бы товар перенесённым на деле
// и неперенесённым в учёте.
func lockTaskForPutaway(ctx context.Context, q Querier, taskID, warehouseID string) error {
	var kind, status, wh string
	err := q.QueryRow(ctx, `
		SELECT kind, status, warehouse_id::text FROM warehouse_tasks
		WHERE id = $1::uuid FOR UPDATE`, taskID).Scan(&kind, &status, &wh)
	if errors.Is(err, pgx.ErrNoRows) {
		return model.ErrTaskNotFound
	}
	if err != nil {
		return fmt.Errorf("заблокировать задание: %w", err)
	}
	if status == model.TaskDone {
		return model.ErrTaskDone
	}
	if kind != model.TaskPutaway || wh != warehouseID {
		return model.ErrTaskMismatch
	}
	return nil
}

// settleTaskAfterPutaway переводит задание после проведённого сеанса.
//
// Всё размещено - задание выполнено. Иначе оно возвращается в пул «новым» без исполнителя:
// частичное «Завершить» отдаёт остаток любому (решение 2026-10-07), - кладовщик мог закончить
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

// TaskRepository - задания для склада: пул, взятие, лента завершённых (P5-02-1).
type TaskRepository struct {
	pool *pgxpool.Pool
}

// NewTaskRepository создаёт репозиторий заданий.
func NewTaskRepository(pool *pgxpool.Pool) *TaskRepository {
	return &TaskRepository{pool: pool}
}

// visibleSQL - условие «задание видно этому пользователю в текущих»: в пуле, взято им самим
// или зависло у другого. $1 - пользователь, $2 - срок, после которого взятое считается зависшим.
const visibleSQL = `t.status <> 'done' AND (
	t.status = 'new' OR t.assignee_id = $1::uuid
	OR t.last_activity_at < now() - $2::interval)`

// taskHeaderSQL - шапка задания с основанием и исполнителем; статус - как его видит $1.
const taskHeaderSQL = `
	SELECT t.id::text, t.number, t.kind,
	       CASE WHEN t.status = 'in_progress' AND t.assignee_id = $1::uuid THEN 'in_progress'
	            WHEN t.status = 'in_progress' THEN 'new'
	            ELSE t.status END,
	       t.warehouse_id::text, t.receipt_id::text, COALESCE(s.name, ''), r.posted_at,
	       r.doc_number, r.doc_date,
	       CASE WHEN t.assignee_id = $1::uuid THEN t.assignee_id::text END,
	       CASE WHEN t.assignee_id = $1::uuid THEN COALESCE(u.full_name, '') ELSE '' END,
	       CASE WHEN t.assignee_id = $1::uuid THEN t.taken_at END,
	       t.created_at, t.stocktake_id::text,
	       wp.id::text, wp.number, t.picking_order_id::text
	FROM warehouse_tasks t
	LEFT JOIN receipts r  ON r.id = t.receipt_id
	LEFT JOIN warehouse_problems wp ON wp.id = t.problem_id
	-- Поставщик: у размещения - поставщик приёмки, у возврата - кому везём (ADHOC-31).
	LEFT JOIN suppliers s ON s.id = COALESCE(r.supplier_id, t.supplier_id)
	LEFT JOIN users u     ON u.id = t.assignee_id`

// Current возвращает текущие задания, видимые пользователю, - пул и свои взятые, с позициями.
// Старые сверху: задание, ждущее дольше, важнее разобрать раньше.
// Размещение и возврат поставщику (ADHOC-31) - оба вида ТСД выполняет.
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

// ByID возвращает задание с позициями - в том виде, в каком его видит пользователь.
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
		return model.Task{}, model.ErrTaskNotFound
	}
	if err := r.attachItems(ctx, tasks); err != nil {
		return model.Task{}, err
	}
	return tasks[0], nil
}

// problemBasis - проблема-основание из LEFT JOIN шапки задания: поля пусты, если основание
// другое.
type problemBasis struct {
	id     *string
	number *int64
}

func (b problemBasis) info() *model.TaskProblemInfo {
	if b.id == nil {
		return nil
	}
	return &model.TaskProblemInfo{ID: *b.id, Number: *b.number}
}

func scanTasks(rows pgx.Rows) ([]model.Task, error) {
	defer rows.Close()
	out := []model.Task{}
	for rows.Next() {
		var t model.Task
		var pr problemBasis
		var pickingOrderID *string
		if err := rows.Scan(&t.ID, &t.Number, &t.Kind, &t.Status, &t.WarehouseID, &t.ReceiptID,
			&t.SupplierName, &t.ReceivedAt, &t.DocNumber, &t.DocDate, &t.AssigneeID, &t.AssigneeName, &t.TakenAt, &t.CreatedAt,
			&t.StocktakeID, &pr.id, &pr.number, &pickingOrderID); err != nil {
			return nil, fmt.Errorf("разобрать задание: %w", err)
		}
		t.Problem = pr.info()
		if pickingOrderID != nil {
			t.Picking = &model.TaskPickingInfo{OrderID: *pickingOrderID}
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// attachItems дочитывает позиции заданий с остатком и составом коробов - двумя запросами
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
	if err := r.attachReturnItems(ctx, tasks, ids, index); err != nil {
		return err
	}
	if err := r.attachStocktakes(ctx, tasks); err != nil {
		return err
	}
	if err := r.attachPickingReturns(ctx, tasks); err != nil {
		return err
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
	for _, t := range tasks {
		for _, it := range t.Items {
			if it.LoadUnitID != nil && it.ProblemID != nil {
				boxIDs = append(boxIDs, *it.LoadUnitID)
			}
		}
	}
	if len(boxIDs) == 0 {
		return nil
	}

	contents, err := r.boxContents(ctx, boxIDs)
	if err != nil {
		return err
	}
	czCodes, err := r.boxCZCodes(ctx, boxIDs)
	if err != nil {
		return err
	}
	for ti := range tasks {
		for ii := range tasks[ti].Items {
			if lu := tasks[ti].Items[ii].LoadUnitID; lu != nil {
				tasks[ti].Items[ii].Contents = contents[*lu]
				if code, ok := czCodes[*lu]; ok {
					tasks[ti].Items[ii].CZCode = &code
				}
			}
		}
	}
	return nil
}

// attachPickingReturns дочитывает к заданиям «вернуть на места» (P9-07-1) заказ-основание и
// сколько осталось вернуть. Основание - удаление заказа или загрузка реестра, последней его
// изменившая.
func (r *TaskRepository) attachPickingReturns(ctx context.Context, tasks []model.Task) error {
	var ids []string
	for _, t := range tasks {
		if t.Picking != nil {
			ids = append(ids, t.Picking.OrderID)
		}
	}
	if len(ids) == 0 {
		return nil
	}
	rows, err := r.pool.Query(ctx, `
		SELECT o.id::text, o.number, o.invoice_number, o.order_number, o.client,
		       o.deleted_at IS NOT NULL, coalesce(o.deleted_at, l.uploaded_at)
		FROM picking_orders o
		LEFT JOIN picking_loads l ON l.id = o.updated_load_id
		WHERE o.id = ANY($1::uuid[])`, ids)
	if err != nil {
		return fmt.Errorf("заказы возврата на места: %w", err)
	}
	infos := map[string]model.TaskPickingInfo{}
	for rows.Next() {
		var p model.TaskPickingInfo
		if err := rows.Scan(&p.OrderID, &p.Number, &p.InvoiceNumber, &p.OrderNumber, &p.Client,
			&p.Deleted, &p.ChangedAt); err != nil {
			rows.Close()
			return fmt.Errorf("заказ возврата на места: %w", err)
		}
		infos[p.OrderID] = p
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return fmt.Errorf("заказы возврата на места: %w", err)
	}
	left, err := returnLeftOf(ctx, r.pool, ids)
	if err != nil {
		return err
	}
	for i := range tasks {
		if tasks[i].Picking == nil {
			continue
		}
		info := infos[tasks[i].Picking.OrderID]
		info.Left = left[info.OrderID]
		tasks[i].Picking = &info
	}
	return nil
}

// attachStocktakes дочитывает к заданиям пересчёта (P10-04) номер, область и ход: сколько
// ячеек всего и сколько подсчитано - одним запросом на список.
func (r *TaskRepository) attachStocktakes(ctx context.Context, tasks []model.Task) error {
	var ids []string
	index := map[string]int{}
	for i, t := range tasks {
		if t.StocktakeID != nil {
			ids = append(ids, *t.StocktakeID)
			index[*t.StocktakeID] = i
		}
	}
	infos, err := r.loadStocktakeInfo(ctx, ids)
	if err != nil {
		return err
	}
	for id, st := range infos {
		tasks[index[id]].Stocktake = st
	}
	return nil
}

// stocktakeInfoSQL - номер, область, автор и ход пересчётов $1: сколько ячеек всего и
// сколько подсчитано. Общий у текущих заданий и ленты «Завершённые».
const stocktakeInfoSQL = `
	SELECT st.id::text, st.number, st.scope_kind, COALESCE(u.full_name, ''),
	       count(sc.id), count(sc.id) FILTER (WHERE sc.status = 'counted')
	FROM stocktakes st
	LEFT JOIN users u ON u.id = st.created_by
	LEFT JOIN stocktake_cells sc ON sc.stocktake_id = st.id
	WHERE st.id = ANY($1::text[]::uuid[])
	GROUP BY st.id, u.full_name`

// loadStocktakeInfo читает пересчёты по id - одним запросом на список.
func (r *TaskRepository) loadStocktakeInfo(ctx context.Context, ids []string) (map[string]*model.TaskStocktakeInfo, error) {
	out := map[string]*model.TaskStocktakeInfo{}
	if len(ids) == 0 {
		return out, nil
	}
	rows, err := r.pool.Query(ctx, stocktakeInfoSQL, ids)
	if err != nil {
		return nil, fmt.Errorf("пересчёты заданий: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		var st model.TaskStocktakeInfo
		if err := rows.Scan(&id, &st.Number, &st.ScopeKind, &st.CreatedBy, &st.Cells, &st.Counted); err != nil {
			return nil, fmt.Errorf("разобрать пересчёт задания: %w", err)
		}
		out[id] = &st
	}
	return out, rows.Err()
}

// attachCompletedStocktakes дочитывает к записям ленты «Завершённые» пересчёт (ADHOC-58):
// без него запись пересчёта показывалась бы как размещение «из приёмки».
func (r *TaskRepository) attachCompletedStocktakes(ctx context.Context, out []model.CompletedTask,
	index map[string]int, stocktakeIDs map[string]string) error {
	ids := make([]string, 0, len(stocktakeIDs))
	for id := range stocktakeIDs {
		ids = append(ids, id)
	}
	infos, err := r.loadStocktakeInfo(ctx, ids)
	if err != nil {
		return err
	}
	for id, st := range infos {
		out[index[stocktakeIDs[id]]].Stocktake = st
	}
	return nil
}

// boxCZCodes - коды коробов ЧЗ среди коробов заданий (CZ-06): ГЕ → `00`+SSCC.
func (r *TaskRepository) boxCZCodes(ctx context.Context, ids []string) (map[string]string, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT load_unit_id::text, code FROM cz_aggregates
		WHERE load_unit_id = ANY($1::uuid[])`, ids)
	if err != nil {
		return nil, fmt.Errorf("коды коробов ЧЗ задания: %w", err)
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var lu, code string
		if err := rows.Scan(&lu, &code); err != nil {
			return nil, fmt.Errorf("разобрать код короба ЧЗ: %w", err)
		}
		out[lu] = code
	}
	return out, rows.Err()
}

// attachReturnItems дочитывает позиции заданий возврата (ADHOC-31): проблемы, решённые
// возвратом в задание, - короб целиком или товар партии с количеством.
//
// Ячейка - где позиция лежит СЕЙЧАС: короб - его место, россыпь - первая ячейка склада
// возврата с этим товаром (сначала та, куда его положило решение). Товар склада возврата
// перемещается, и место из строки решения могло устареть. Отгруженная позиция - Placed.
func (r *TaskRepository) attachReturnItems(ctx context.Context, tasks []model.Task, ids []string, index map[string]int) error {
	rows, err := r.pool.Query(ctx, `
		SELECT p.return_task_id::text, p.id::text, p.load_unit_id::text, p.shipment_id IS NOT NULL,
		       g.id::text, g.code, g.name, g.uom, p.batch_id::text, b.production_date,
		       COALESCE(p.qty, 0)::text,
		       COALESCE(
		           (SELECT c.address FROM load_units lu JOIN cells c ON c.id = lu.cell_id
		            WHERE lu.id = p.load_unit_id),
		           (SELECT c.address FROM stock st JOIN cells c ON c.id = st.cell_id
		            JOIN internal_warehouses w ON w.id = st.internal_warehouse_id AND w.system_role = $2
		            WHERE st.good_id = p.good_id AND st.batch_id = p.batch_id AND st.qty > 0
		              AND c.warehouse_id = p.warehouse_id
		            ORDER BY st.cell_id = (SELECT l.cell_id FROM warehouse_problem_lines l
		                                   WHERE l.problem_id = p.id ORDER BY l.line_no LIMIT 1) DESC,
		                     c.address
		            LIMIT 1),
		           '')
		FROM warehouse_problems p
		LEFT JOIN goods g   ON g.id = p.good_id
		LEFT JOIN batches b ON b.id = p.batch_id
		WHERE p.return_task_id = ANY($1::uuid[])
		ORDER BY p.return_task_id, p.resolved_at, p.id`, ids, model.InternalWarehouseRoleSupplierReturn)
	if err != nil {
		return fmt.Errorf("позиции заданий возврата: %w", err)
	}
	defer rows.Close()
	lineNo := map[string]int{}
	for rows.Next() {
		var taskID, problemID, qty string
		var it model.PutawayTaskItem
		var gid, gcode, gname, guom *string
		if err := rows.Scan(&taskID, &problemID, &it.LoadUnitID, &it.Placed, &gid, &gcode, &gname,
			&guom, &it.BatchID, &it.ProductionDate, &qty, &it.CellAddress); err != nil {
			return fmt.Errorf("разобрать позицию возврата: %w", err)
		}
		lineNo[taskID]++
		it.LineNo = lineNo[taskID]
		it.ProblemID = &problemID
		if it.LoadUnitID == nil {
			it.Good = &model.TaskGood{ID: *gid, Code: deref(gcode), Name: deref(gname), Uom: deref(guom)}
			it.Qty, _ = decimal.NewFromString(qty)
			if !it.Placed {
				it.Remaining = it.Qty
			}
		}
		t := &tasks[index[taskID]]
		t.Items = append(t.Items, it)
	}
	if err := rows.Err(); err != nil {
		return err
	}
	rows.Close()
	return r.attachReturnMarks(ctx, tasks, ids, index)
}

// attachReturnMarks дочитывает марки ЧЗ позиций возврата россыпью (CZ-06, долг 30): ТСД
// считает «отсканировано N из M» без связи.
func (r *TaskRepository) attachReturnMarks(ctx context.Context, tasks []model.Task, ids []string, index map[string]int) error {
	rows, err := r.pool.Query(ctx, `
		SELECT p.return_task_id::text, p.id::text, m.cis
		FROM warehouse_problems p
		JOIN cz_marks m ON m.problem_id = p.id AND m.status = $2 AND m.load_unit_id IS NULL
		WHERE p.return_task_id = ANY($1::uuid[]) AND p.load_unit_id IS NULL
		ORDER BY m.cis`, ids, model.CZMarkInStock)
	if err != nil {
		return fmt.Errorf("марки позиций возврата: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var taskID, problemID, cis string
		if err := rows.Scan(&taskID, &problemID, &cis); err != nil {
			return fmt.Errorf("разобрать марку позиции возврата: %w", err)
		}
		items := tasks[index[taskID]].Items
		for i := range items {
			if items[i].ProblemID != nil && *items[i].ProblemID == problemID {
				items[i].Marks = append(items[i].Marks, cis)
			}
		}
	}
	return rows.Err()
}

// boxContents - состав коробов с товаром и датой партии.
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
// Повтор своим исполнителем - не ошибка и не событие: кладовщик нажал «Взять» дважды или
// ответ не дошёл. Взятие из пула пишется в журнал как taken, перехват зависшего - как
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
			return model.ErrTaskNotFound
		case err != nil:
			return fmt.Errorf("взять задание: %w", err)
		case status == model.TaskDone:
			return model.ErrTaskDone
		}

		event, prev := model.TaskEventTaken, ""
		if status == model.TaskInProgress {
			switch {
			case holder != nil && *holder == userID:
				return nil
			case !stale:
				return model.ErrTaskTaken
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

// Release возвращает своё взятое задание в пул. Задание уже в пуле - не ошибка (повтор).
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
		return model.ErrTaskNotFound
	case err != nil:
		return fmt.Errorf("отказаться от задания: %w", err)
	case status == model.TaskNew:
		return nil
	case status == model.TaskDone:
		return model.ErrTaskDone
	default:
		return model.ErrTaskTaken
	}
}

// addTaskEvent дописывает событие в журнал задания - в транзакции того, что его вызвало.
// Пустые userID, prevUserID, putawayID - «нет» (системное событие, не перехват, не заход).
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

// Events - журнал задания по порядку: что случилось, кто и когда.
//
// У пересчёта (ADHOC-58) в журнал вплетаются подсчитанные ячейки - кто и какую посчитал:
// работники берут ячейки, а не задание, и без них история пересчёта - только «создано» и
// «выполнено». Порядок - по времени; события одной транзакции - по seq журнала.
func (r *TaskRepository) Events(ctx context.Context, taskID string) ([]model.TaskEvent, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT event, user_name, prev_user_name, putaway_id, cell, at FROM (
			SELECT e.event, COALESCE(u.full_name, '') AS user_name, COALESCE(pu.full_name, '') AS prev_user_name,
			       e.putaway_id::text AS putaway_id, '' AS cell, e.at, e.seq
			FROM task_events e
			LEFT JOIN users u  ON u.id = e.user_id
			LEFT JOIN users pu ON pu.id = e.prev_user_id
			WHERE e.task_id = $1::uuid
			UNION ALL
			SELECT '`+model.TaskEventCellCounted+`', COALESCE(u.full_name, ''), '', NULL, c.address, sc.counted_at, 0
			FROM warehouse_tasks t
			JOIN stocktake_cells sc ON sc.stocktake_id = t.stocktake_id AND sc.status = 'counted'
			JOIN cells c ON c.id = sc.cell_id
			LEFT JOIN users u ON u.id = sc.counted_by
			WHERE t.id = $1::uuid
		) ev
		ORDER BY at, seq, cell`, taskID)
	if err != nil {
		return nil, fmt.Errorf("журнал задания: %w", err)
	}
	defer rows.Close()
	out := []model.TaskEvent{}
	for rows.Next() {
		var ev model.TaskEvent
		if err := rows.Scan(&ev.Event, &ev.UserName, &ev.PrevUserName, &ev.PutawayID, &ev.Cell, &ev.At); err != nil {
			return nil, fmt.Errorf("разобрать событие задания: %w", err)
		}
		out = append(out, ev)
	}
	return out, rows.Err()
}

// taskSessionsSQL - заходы по заданиям всех видов: сеансы размещения и отгрузки возврата
// (ADHOC-31), у пересчёта - подсчитанные ячейки (ADHOC-58). Лента «Завершённые» считает по
// ним заходы и исполнителей, по ним же работает фильтр по исполнителю.
const taskSessionsSQL = `(
	SELECT task_id, created_by, posted_at FROM putaways
	UNION ALL
	SELECT task_id, created_by, posted_at FROM supplier_return_shipments
	UNION ALL
	-- Возврат на места (P9-07-1): заход - каждый возврат из короба отгрузки.
	SELECT task_id, returned_by, returned_at FROM picking_returns
	UNION ALL
	SELECT wt.id, sc.counted_by, sc.counted_at
	FROM stocktake_cells sc JOIN warehouse_tasks wt ON wt.stocktake_id = sc.stocktake_id
	WHERE sc.status = 'counted')`

// Completed - страница ленты «Завершённые»: свежие сверху, подгрузка курсором.
func (r *TaskRepository) Completed(ctx context.Context, f model.CompletedTasksFilter) ([]model.CompletedTask, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT t.id::text, t.number, t.kind, COALESCE(s.name, ''), r.doc_number, r.doc_date, t.completed_at,
		       (SELECT count(*) FROM `+taskSessionsSQL+` x WHERE x.task_id = t.id),
		       wp.id::text, wp.number, t.stocktake_id::text,
		       po.id::text, po.number, po.invoice_number, po.order_number, po.client, po.deleted_at IS NOT NULL
		FROM warehouse_tasks t
		LEFT JOIN receipts r  ON r.id = t.receipt_id
		LEFT JOIN warehouse_problems wp ON wp.id = t.problem_id
		LEFT JOIN suppliers s ON s.id = COALESCE(r.supplier_id, t.supplier_id)
		LEFT JOIN picking_orders po ON po.id = t.picking_order_id
		WHERE t.status = 'done'
		  AND ($1::timestamptz IS NULL OR t.completed_at >= $1)
		  AND ($2::timestamptz IS NULL OR t.completed_at <  $2)
		  AND ($3::text = '' OR t.kind = $3)
		  AND ($4::text = '' OR EXISTS (
		      SELECT 1 FROM `+taskSessionsSQL+` x WHERE x.task_id = t.id AND x.created_by = NULLIF($4, '')::uuid))
		  AND ($5::timestamptz IS NULL OR (t.completed_at, t.id) < ($5, NULLIF($6, '')::uuid))
		ORDER BY t.completed_at DESC, t.id DESC
		LIMIT $7`,
		f.From, f.To, f.Kind, f.ExecutorID, f.BeforeCompletedAt, f.BeforeID, f.Limit)
	if err != nil {
		return nil, fmt.Errorf("завершённые задания: %w", err)
	}
	out := []model.CompletedTask{}
	index := map[string]int{}
	stocktakeIDs := map[string]string{} // id пересчёта → id задания
	for rows.Next() {
		var c model.CompletedTask
		var pr problemBasis
		var stocktakeID *string
		var po struct {
			id, invoice, order, client *string
			number                     *int64
			deleted                    *bool
		}
		if err := rows.Scan(&c.ID, &c.Number, &c.Kind, &c.SupplierName, &c.DocNumber, &c.DocDate, &c.CompletedAt, &c.Sessions,
			&pr.id, &pr.number, &stocktakeID, &po.id, &po.number, &po.invoice, &po.order, &po.client, &po.deleted); err != nil {
			rows.Close()
			return nil, fmt.Errorf("разобрать завершённое задание: %w", err)
		}
		c.Problem = pr.info()
		if po.id != nil {
			c.Picking = &model.TaskPickingInfo{OrderID: *po.id, Number: *po.number, InvoiceNumber: *po.invoice,
				OrderNumber: *po.order, Client: *po.client, Deleted: *po.deleted}
		}
		if stocktakeID != nil {
			stocktakeIDs[*stocktakeID] = c.ID
		}
		index[c.ID] = len(out)
		out = append(out, c)
	}
	rows.Close()
	if err := rows.Err(); err != nil || len(out) == 0 {
		return out, err
	}
	if err := r.attachCompletedStocktakes(ctx, out, index, stocktakeIDs); err != nil {
		return nil, err
	}

	ids := make([]string, len(out))
	for i, c := range out {
		ids[i] = c.ID
	}
	ex, err := r.pool.Query(ctx, `
		SELECT x.task_id::text, u.id::text, u.full_name
		FROM `+taskSessionsSQL+` x JOIN users u ON u.id = x.created_by
		WHERE x.task_id = ANY($1::uuid[])
		GROUP BY x.task_id, u.id, u.full_name
		ORDER BY x.task_id, min(x.posted_at)`, ids)
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

// Executors - все, кто когда-либо выполнял задания: варианты фильтра ленты по исполнителю.
func (r *TaskRepository) Executors(ctx context.Context) ([]model.TaskUser, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT DISTINCT u.id::text, u.full_name
		FROM `+taskSessionsSQL+` x JOIN users u ON u.id = x.created_by
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

// Sessions - заходы по заданию: проведённые сеансы размещения со строками, по порядку.
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

// intervalOf - длительность в виде, который Postgres примет как interval.
func intervalOf(d time.Duration) string {
	return fmt.Sprintf("%d seconds", int64(d.Seconds()))
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}
