package repository_test

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// Тесты P5-02-1: задания для склада. Критерий задачи — после оприходования приёмки задание на
// размещение видно в текущих; взятие, отказ и авто-возврат работают; задание переходит
// в завершённые, когда размещено всё.

const stale = 8 * time.Hour

// newUserNamed заводит ещё одного кладовщика.
func newUserNamed(t *testing.T, pf *putawayFixture, login, name string) string {
	t.Helper()
	var id string
	mustScan(t, pf.pool, `INSERT INTO users (login, password_hash, full_name, role)
		VALUES ($1,'x',$2,'employee') RETURNING id::text`, &id, login, name)
	return id
}

func visibleTo(t *testing.T, repo *repository.TaskRepository, user, task string) (model.Task, bool) {
	t.Helper()
	tasks, err := repo.Current(context.Background(), user, stale)
	mustNoErr(t, err)
	for _, x := range tasks {
		if x.ID == task {
			return x, true
		}
	}
	return model.Task{}, false
}

// Приёмка рождает задание из того, что легло в ячейку приёмки: короб одной позицией, россыпь
// с партией и количеством. Приёмка прямо в ячейку хранения задания не рождает.
func TestTasks_receiptCreatesPutawayTask(t *testing.T) {
	pf := setupPutaway(t)
	repo := repository.NewTaskRepository(pf.pool)
	lu := newLU(t, pf.stockFixture, model.LoadUnitBox)
	task := pf.receive(t, []string{lu}, 5)

	got, ok := visibleTo(t, repo, pf.user, task)
	if !ok || got.Kind != model.TaskPutaway || got.Status != model.TaskNew || got.Number <= 0 {
		t.Fatalf("задание после приёмки: %+v (видно: %v)", got, ok)
	}
	if len(got.Items) != 2 {
		t.Fatalf("позиций: %d, ожидалось 2", len(got.Items))
	}
	box, loose := got.Items[0], got.Items[1]
	if box.LoadUnitID == nil || *box.LoadUnitID != lu || len(box.Contents) != 1 || box.Contents[0].Qty.String() != "12" {
		t.Errorf("позиция-короб: %+v", box)
	}
	if loose.Good == nil || loose.Qty.String() != "5" || loose.Remaining.String() != "5" || loose.ProductionDate == nil {
		t.Errorf("позиция-россыпь: %+v", loose)
	}

	// Приёмка в ячейку хранения: в зоне приёмки ничего — задания нет.
	ctx := context.Background()
	rr := repository.NewReceiptRepository(pf.pool)
	receipt := uuid.NewString()
	mustNoErr(t, rr.Create(ctx, receipt, pf.wh, "", pf.user))
	mustNoErr(t, rr.AddLine(ctx, receipt, model.ReceiptLineInput{
		GoodID: pf.good, ProductionDate: "2026-01-01", CellID: pf.cellB, Qty: decimal.NewFromInt(1),
	}))
	if _, err := rr.Post(ctx, receipt); err != nil {
		t.Fatalf("приёмка в ячейку хранения: %v", err)
	}
	var n int
	mustScanInt(t, pf, `SELECT count(*) FROM warehouse_tasks WHERE receipt_id = $1::uuid`, &n, receipt)
	if n != 0 {
		t.Errorf("приёмка без зоны приёмки родила %d заданий", n)
	}
}

// Пул: взятое задание видно только взявшему; другой не может его взять, пока оно не зависло.
func TestTasks_takeReleaseAndStale(t *testing.T) {
	pf := setupPutaway(t)
	ctx := context.Background()
	repo := repository.NewTaskRepository(pf.pool)
	other := newUserNamed(t, pf, "90000088", "Второй")
	task := pf.receive(t, []string{newLU(t, pf.stockFixture, model.LoadUnitBox)}, 0)

	mustNoErr(t, repo.Take(ctx, task, pf.user, stale))
	mustNoErr(t, repo.Take(ctx, task, pf.user, stale)) // повтор своим — не ошибка
	if mine, ok := visibleTo(t, repo, pf.user, task); !ok || mine.Status != model.TaskInProgress || mine.AssigneeName == "" {
		t.Errorf("взявший видит: %+v (видно: %v)", mine, ok)
	}
	if _, ok := visibleTo(t, repo, other, task); ok {
		t.Error("взятое задание видно другому")
	}
	if err := repo.Take(ctx, task, other, stale); !errors.Is(err, repository.ErrTaskTaken) {
		t.Errorf("взять чужое: %v, ожидалась ErrTaskTaken", err)
	}
	if err := repo.Release(ctx, task, other); !errors.Is(err, repository.ErrTaskTaken) {
		t.Errorf("отказаться за другого: %v, ожидалась ErrTaskTaken", err)
	}

	// Отказ возвращает в пул; повторный отказ — не ошибка.
	mustNoErr(t, repo.Release(ctx, task, pf.user))
	mustNoErr(t, repo.Release(ctx, task, pf.user))
	if got, ok := visibleTo(t, repo, other, task); !ok || got.Status != model.TaskNew {
		t.Errorf("после отказа другой видит: %+v (видно: %v)", got, ok)
	}

	// Зависло: взятое и брошенное на 9 часов снова видно всем «новым» и берётся другим.
	mustNoErr(t, repo.Take(ctx, task, pf.user, stale))
	if _, err := pf.pool.Exec(ctx, `UPDATE warehouse_tasks SET last_activity_at = now() - interval '9 hours'
		WHERE id = $1::uuid`, task); err != nil {
		t.Fatal(err)
	}
	if got, ok := visibleTo(t, repo, other, task); !ok || got.Status != model.TaskNew {
		t.Errorf("зависшее задание другой видит: %+v (видно: %v)", got, ok)
	}
	mustNoErr(t, repo.Take(ctx, task, other, stale))
}

// Частичное «Завершить» возвращает остаток в пул «новым»; размещено всё — задание выполнено
// и уходит в ленту с исполнителями обоих заходов.
func TestTasks_partialThenDone(t *testing.T) {
	pf := setupPutaway(t)
	ctx := context.Background()
	repo := repository.NewTaskRepository(pf.pool)
	other := newUserNamed(t, pf, "90000088", "Второй")
	lu := newLU(t, pf.stockFixture, model.LoadUnitBox)
	task := pf.receive(t, []string{lu}, 5)

	mustNoErr(t, repo.Take(ctx, task, pf.user, stale))
	if _, err := pf.submit(t, task, uuid.NewString(), boxTo(lu, pf.cellB), looseTo(pf.good, 2, pf.cellB)); err != nil {
		t.Fatalf("частичный заход: %v", err)
	}
	got, ok := visibleTo(t, repo, other, task)
	if !ok || got.Status != model.TaskNew {
		t.Fatalf("после частичного заход задание: %+v (видно другому: %v)", got, ok)
	}
	if !got.Items[0].Placed || got.Items[1].Remaining.String() != "3" {
		t.Errorf("остаток задания: короб размещён=%v, россыпи осталось %s", got.Items[0].Placed, got.Items[1].Remaining)
	}

	// Второй заход другим кладовщиком закрывает задание.
	if _, err := pf.ops.PutawaySubmit(ctx, uuid.NewString(), repository.PutawaySubmitInput{
		PutawayID: uuid.NewString(), TaskID: task, WarehouseID: pf.wh, CreatedBy: other,
		Lines: []repository.PutawayLineInput{looseTo(pf.good, 3, pf.cellB)},
	}); err != nil {
		t.Fatalf("завершающий заход: %v", err)
	}
	if _, ok := visibleTo(t, repo, pf.user, task); ok {
		t.Error("выполненное задание осталось в текущих")
	}
	done, err := repo.Completed(ctx, model.CompletedTasksFilter{Limit: 10})
	mustNoErr(t, err)
	if len(done) != 1 || done[0].ID != task || done[0].Sessions != 2 || len(done[0].Executors) != 2 {
		t.Fatalf("лента: %+v", done)
	}
	if done[0].Executors[0].ID != pf.user || done[0].Executors[1].ID != other {
		t.Errorf("исполнители не в порядке первого захода: %+v", done[0].Executors)
	}
	sessions, err := repo.Sessions(ctx, task)
	mustNoErr(t, err)
	if len(sessions) != 2 || len(sessions[0].Lines) != 2 || sessions[0].Lines[0].ToAddress != "B" {
		t.Errorf("заходы: %+v", sessions)
	}

	// Выполненное задание больше не размещается.
	if _, err := pf.submit(t, task, uuid.NewString(), looseTo(pf.good, 1, pf.cellB)); !errors.Is(err, repository.ErrTaskDone) {
		t.Errorf("размещение по выполненному: %v, ожидалась ErrTaskDone", err)
	}
}

// Лента: фильтр по исполнителю и подгрузка курсором без повторов и пропусков.
func TestTasks_completedFilterAndPaging(t *testing.T) {
	pf := setupPutaway(t)
	ctx := context.Background()
	repo := repository.NewTaskRepository(pf.pool)
	other := newUserNamed(t, pf, "90000088", "Второй")

	var all []string
	for i := 0; i < 3; i++ {
		lu := newLU(t, pf.stockFixture, model.LoadUnitBox)
		task := pf.receive(t, []string{lu}, 0)
		by := pf.user
		if i == 2 {
			by = other
		}
		if _, err := pf.ops.PutawaySubmit(ctx, uuid.NewString(), repository.PutawaySubmitInput{
			PutawayID: uuid.NewString(), TaskID: task, WarehouseID: pf.wh, CreatedBy: by,
			Lines: []repository.PutawayLineInput{boxTo(lu, pf.cellB)},
		}); err != nil {
			t.Fatal(err)
		}
		all = append(all, task)
	}

	mine, err := repo.Completed(ctx, model.CompletedTasksFilter{ExecutorID: other, Limit: 10})
	mustNoErr(t, err)
	if len(mine) != 1 || mine[0].ID != all[2] {
		t.Errorf("фильтр по исполнителю: %+v", mine)
	}

	var seen []string
	f := model.CompletedTasksFilter{Kind: model.TaskPutaway, Limit: 2}
	for page := 0; page < 3; page++ {
		got, err := repo.Completed(ctx, f)
		mustNoErr(t, err)
		if len(got) == 0 {
			break
		}
		for _, c := range got {
			seen = append(seen, c.ID)
		}
		last := got[len(got)-1]
		f.BeforeCompletedAt, f.BeforeID = &last.CompletedAt, last.ID
	}
	if len(seen) != 3 || seen[0] != all[2] || seen[2] != all[0] {
		t.Errorf("подгрузка: %v, ожидались %v в обратном порядке", seen, all)
	}

	future := time.Now().Add(time.Hour)
	none, err := repo.Completed(ctx, model.CompletedTasksFilter{From: &future, Limit: 10})
	mustNoErr(t, err)
	if len(none) != 0 {
		t.Errorf("фильтр по периоду пропустил %d записей", len(none))
	}
}

// Миграция 000019 заводит задания приёмкам, оприходованным до заданий.
func TestTasks_migrationBackfillsReceipts(t *testing.T) {
	pf := setupPutaway(t)
	lu := newLU(t, pf.stockFixture, model.LoadUnitBox)
	pf.receive(t, []string{lu}, 5)

	execMigration(t, pf.stockFixture, "000020_task_events.down.sql")
	execMigration(t, pf.stockFixture, "000019_warehouse_tasks.down.sql")
	execMigration(t, pf.stockFixture, "000019_warehouse_tasks.up.sql")
	execMigration(t, pf.stockFixture, "000020_task_events.up.sql")

	repo := repository.NewTaskRepository(pf.pool)
	tasks, err := repo.Current(context.Background(), pf.user, stale)
	mustNoErr(t, err)
	if len(tasks) != 1 || len(tasks[0].Items) != 2 || tasks[0].ReceiptID == nil {
		t.Fatalf("задания после миграции: %+v", tasks)
	}
	// Миграция 000020 восстанавливает журнал: у прежнего задания есть хотя бы «создано».
	events, err := repo.Events(context.Background(), tasks[0].ID)
	mustNoErr(t, err)
	if len(events) != 1 || events[0].Event != model.TaskEventCreated {
		t.Errorf("журнал после миграции: %+v", events)
	}
}

// Журнал задания: создано системой, взято, отказ, снова взято, перехвачено как зависшее,
// заход и завершение — по порядку и с теми, кто это сделал.
func TestTasks_eventsJournal(t *testing.T) {
	pf := setupPutaway(t)
	ctx := context.Background()
	repo := repository.NewTaskRepository(pf.pool)
	other := newUserNamed(t, pf, "90000088", "Второй")
	lu := newLU(t, pf.stockFixture, model.LoadUnitBox)
	task := pf.receive(t, []string{lu}, 0)

	mustNoErr(t, repo.Take(ctx, task, pf.user, stale))
	mustNoErr(t, repo.Take(ctx, task, pf.user, stale)) // повтор своим — не событие
	mustNoErr(t, repo.Release(ctx, task, pf.user))
	mustNoErr(t, repo.Release(ctx, task, pf.user)) // повторный отказ — не событие
	mustNoErr(t, repo.Take(ctx, task, pf.user, stale))
	if _, err := pf.pool.Exec(ctx, `UPDATE warehouse_tasks SET last_activity_at = now() - interval '9 hours'
		WHERE id = $1::uuid`, task); err != nil {
		t.Fatal(err)
	}
	mustNoErr(t, repo.Take(ctx, task, other, stale))
	putaway := uuid.NewString()
	if _, err := pf.ops.PutawaySubmit(ctx, uuid.NewString(), repository.PutawaySubmitInput{
		PutawayID: putaway, TaskID: task, WarehouseID: pf.wh, CreatedBy: other,
		Lines: []repository.PutawayLineInput{boxTo(lu, pf.cellB)},
	}); err != nil {
		t.Fatal(err)
	}

	events, err := repo.Events(ctx, task)
	mustNoErr(t, err)
	var got []string
	for _, e := range events {
		got = append(got, e.Event)
	}
	want := []string{
		model.TaskEventCreated, model.TaskEventTaken, model.TaskEventReleased, model.TaskEventTaken,
		model.TaskEventIntercepted, model.TaskEventSession, model.TaskEventCompleted,
	}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("журнал: %v, ожидалось %v", got, want)
	}
	if events[0].UserName != "" {
		t.Errorf("создание приёмкой — системное событие, автор: %q", events[0].UserName)
	}
	if ic := events[4]; ic.UserName != "Второй" || ic.PrevUserName != "Кладовщик" {
		t.Errorf("перехват: кто %q, у кого %q", ic.UserName, ic.PrevUserName)
	}
	if s := events[5]; s.PutawayID == nil || *s.PutawayID != putaway {
		t.Errorf("заход без ссылки на документ: %+v", s)
	}
}
