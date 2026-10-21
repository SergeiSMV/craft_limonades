package repository_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// Тесты P6-07-3: решение офиса по проблеме — списать, разместить, вернуть поставщику. Товар
// проблемы берётся там, где лежит сейчас; решение — целиком и один раз. Фикстура setupMove —
// из movement_integration_test.go, пометка — из problem_integration_test.go.

// openProblem фиксирует проблему и возвращает её идентификатор.
func (mf *moveFixture) openProblem(t *testing.T, to, reason string, in repository.ProblemSubmitInput) string {
	t.Helper()
	in.Reason = reason
	id := uuid.NewString()
	in.ProblemID, in.WarehouseID, in.CreatedBy, in.ToInternalWarehouseID = id, mf.wh, mf.user, to
	if in.Reason == model.ProblemReasonOther {
		in.Comment = "развакуум"
	}
	if err := repository.ProblemSubmitForTest(context.Background(), mf.pool, in); err != nil {
		t.Fatalf("пометка: %v", err)
	}
	return id
}

// resolve проводит решение по проблеме от пользователя фикстуры.
func (mf *moveFixture) resolve(id string, in model.ResolveProblemInput) error {
	in.ProblemID, in.ResolvedBy = id, mf.user
	return repository.NewProblemRepository(mf.pool).Resolve(context.Background(), in)
}

// supplier заводит поставщика.
func (mf *moveFixture) supplier(t *testing.T, name string) string {
	t.Helper()
	var id string
	mustScan(t, mf.pool, `INSERT INTO suppliers (name) VALUES ($1) RETURNING id::text`, &id, name)
	return id
}

// Списание россыпи, которая после пометки частью переехала: решение берёт её сначала в ячейке
// пометки, потом там, куда её перенесли; «Основной» рядом не задет; повтор — отказ.
func TestProblemResolve_writeOffMovedGoods(t *testing.T) {
	mf := setupMove(t)
	defect := mf.iwhByCode(t, "DEFECT")
	mf.receive(t, nil, 5) // A: россыпь 5
	id := mf.openProblem(t, defect, model.ProblemReasonSpoilage, mf.goodsProblem(2, mf.cellA, ""))

	part := mf.goodsLine(1, mf.cellA, "", mf.cellC, "")
	part.InternalWarehouseID = defect
	if _, err := mf.move(t, uuid.NewString(), part); err != nil {
		t.Fatalf("перенос брака: %v", err)
	}

	writeOff := model.ResolveProblemInput{Decision: model.ProblemDecisionWriteOff, DocNumber: "СП-17", DocDate: "2026-10-21"}
	if err := mf.resolve(id, writeOff); err != nil {
		t.Fatalf("списание: %v", err)
	}
	if a, c, main := mf.qtyIn(t, mf.cellA, defect), mf.qtyIn(t, mf.cellC, defect), mf.qtyIn(t, mf.cellA, mf.iwh); a != "0" || c != "0" || main != "3" {
		t.Errorf("брак A %s, брак C %s, основной A %s; ожидалось 0, 0, 3", a, c, main)
	}
	var rec string
	mustScan(t, mf.pool, `
		SELECT status || ' ' || decision || ' ' || doc_number || ' ' || doc_date::text || ' ' ||
		       (SELECT string_agg(c.address || ':' || l.qty::text, ',' ORDER BY l.line_no)
		        FROM warehouse_problem_lines l JOIN cells c ON c.id = l.cell_id WHERE l.problem_id = p.id)
		FROM warehouse_problems p WHERE id = $1::uuid`, &rec, id)
	if rec != "resolved write_off СП-17 2026-10-21 A:1.000,C:1.000" {
		t.Errorf("запись решения: %q", rec)
	}
	if err := mf.resolve(id, writeOff); !errors.Is(err, repository.ErrProblemResolved) {
		t.Errorf("повторное решение: %v", err)
	}
}

// Короб «не нашей марки» размещается: метка снимается с короба и его остатка в той же ячейке.
// Бой разместить нельзя — только списать.
func TestProblemResolve_placeBoxAndNotAllowed(t *testing.T) {
	mf := setupMove(t)
	iso := mf.iwhByCode(t, "ISOLATOR")
	lu := newLU(t, mf.stockFixture, model.LoadUnitBox)
	mf.receive(t, []string{lu}, 5)
	id := mf.openProblem(t, iso, model.ProblemReasonForeignMark, repository.ProblemSubmitInput{LoadUnitID: lu})

	if err := mf.resolve(id, model.ResolveProblemInput{Decision: model.ProblemDecisionPlace}); err != nil {
		t.Fatalf("размещение: %v", err)
	}
	if main, isoQty := mf.qtyIn(t, mf.cellA, mf.iwh), mf.qtyIn(t, mf.cellA, iso); main != "17" || isoQty != "0" {
		t.Errorf("A: основной %s изолятор %s, ожидалось 17 и 0", main, isoQty)
	}
	var boxIwh string
	mustScan(t, mf.pool, `SELECT internal_warehouse_id::text FROM load_units WHERE id = $1::uuid`, &boxIwh, lu)
	if boxIwh != mf.iwh {
		t.Errorf("склад короба %s, ожидался основной", boxIwh)
	}

	breakage := mf.openProblem(t, mf.iwhByCode(t, "DEFECT"), model.ProblemReasonBreakage, mf.goodsProblem(1, mf.cellA, ""))
	if err := mf.resolve(breakage, model.ResolveProblemInput{Decision: model.ProblemDecisionPlace}); !errors.Is(err, repository.ErrDecisionNotAllowed) {
		t.Errorf("бой — разместить: %v", err)
	}
}

// Возврат: товар переходит на склад возврата и копится в одном открытом задании поставщика;
// ТСД видит задание возврата; на склад возврата не помечают и с него не перепомечают.
func TestProblemResolve_supplierReturn(t *testing.T) {
	mf := setupMove(t)
	defect := mf.iwhByCode(t, "DEFECT")
	ret := mf.iwhByCode(t, "RETURN")
	sup := mf.supplier(t, "ООО Вкуснярики")
	lu := newLU(t, mf.stockFixture, model.LoadUnitBox)
	mf.receive(t, []string{lu}, 5)

	box := mf.openProblem(t, defect, model.ProblemReasonExpired, repository.ProblemSubmitInput{LoadUnitID: lu})
	loose := mf.openProblem(t, defect, model.ProblemReasonOther, mf.goodsProblem(2, mf.cellA, ""))
	back := model.ResolveProblemInput{Decision: model.ProblemDecisionSupplierReturn, SupplierID: sup}
	if err := mf.resolve(box, back); err != nil {
		t.Fatalf("возврат короба: %v", err)
	}
	if err := mf.resolve(loose, back); err != nil {
		t.Fatalf("возврат россыпи: %v", err)
	}
	if r, d := mf.qtyIn(t, mf.cellA, ret), mf.qtyIn(t, mf.cellA, defect); r != "14" || d != "0" {
		t.Errorf("A: возврат %s брак %s, ожидалось 14 и 0", r, d)
	}
	var tasks string
	mustScan(t, mf.pool, `
		SELECT count(DISTINCT p.return_task_id)::text || ' ' || min(t.kind) || ' ' || min(t.status)
		FROM warehouse_problems p JOIN warehouse_tasks t ON t.id = p.return_task_id
		WHERE t.supplier_id = $1::uuid`, &tasks, sup)
	if tasks != "1 supplier_return new" {
		t.Errorf("задания возврата: %q", tasks)
	}
	// ТСД видит задание возврата с двумя позициями, ячейкой и поставщиком (ADHOC-31).
	current, err := repository.NewTaskRepository(mf.pool).Current(context.Background(), mf.user, 0)
	mustNoErr(t, err)
	var found bool
	for _, task := range current {
		if task.Kind == model.TaskSupplierReturn {
			found = true
			if task.SupplierName != "ООО Вкуснярики" || len(task.Items) != 2 || task.Items[0].CellAddress != "A" {
				t.Errorf("задание возврата на ТСД: %+v", task)
			}
		}
	}
	if !found {
		t.Error("ТСД не видит задание возврата")
	}

	if err := mf.problem(t, ret, mf.goodsProblem(1, mf.cellA, "")); !errors.Is(err, repository.ErrSystemInternalWarehouse) {
		t.Errorf("пометка на склад возврата: %v", err)
	}
	fromReturn := mf.goodsProblem(1, mf.cellA, "")
	fromReturn.FromInternalWarehouseID = ret
	if err := mf.problem(t, defect, fromReturn); !errors.Is(err, repository.ErrSystemInternalWarehouse) {
		t.Errorf("пометка товара со склада возврата: %v", err)
	}
	if _, err := repository.NewInternalWarehouseRepository(mf.pool).Update(context.Background(), ret, nil, new(bool)); !errors.Is(err, repository.ErrSystemInternalWarehouse) {
		t.Errorf("скрыть склад возврата: %v", err)
	}
}

// Короб перепометили другим складом — у первой проблемы товара на её складе больше нет.
func TestProblemResolve_goodsMissing(t *testing.T) {
	mf := setupMove(t)
	lu := newLU(t, mf.stockFixture, model.LoadUnitBox)
	mf.receive(t, []string{lu}, 0)
	first := mf.openProblem(t, mf.iwhByCode(t, "DEFECT"), model.ProblemReasonBreakage, repository.ProblemSubmitInput{LoadUnitID: lu})
	mf.openProblem(t, mf.iwhByCode(t, "ISOLATOR"), model.ProblemReasonForeignMark, repository.ProblemSubmitInput{LoadUnitID: lu})

	err := mf.resolve(first, model.ResolveProblemInput{Decision: model.ProblemDecisionWriteOff, DocNumber: "1", DocDate: "2026-10-21"})
	if !errors.Is(err, repository.ErrProblemGoodsMissing) {
		t.Errorf("решение по перепомеченному коробу: %v", err)
	}
}

// Рабочий список: открытая — с составом короба и допустимыми решениями по причине.
func TestProblemList_openBox(t *testing.T) {
	mf := setupMove(t)
	lu := newLU(t, mf.stockFixture, model.LoadUnitBox)
	mf.receive(t, []string{lu}, 0)
	mf.openProblem(t, mf.iwhByCode(t, "DEFECT"), model.ProblemReasonBreakage, repository.ProblemSubmitInput{LoadUnitID: lu})

	list, err := repository.NewProblemRepository(mf.pool).List(context.Background(), model.ProblemFilter{Status: model.ProblemStatusOpen})
	mustNoErr(t, err)
	if len(list) != 1 || list[0].LoadUnitID != lu || len(list[0].Items) != 1 ||
		list[0].Items[0].Qty != "12.000" || list[0].Items[0].CellAddress != "A" || list[0].ToWarehouse != "Брак" {
		t.Errorf("список: %+v", list)
	}
}

// ADHOC-34: лента решённых на ТСД — только решённые, свежие решения первыми, курсор продолжает
// без повторов, окно — по времени решения.
func TestProblemResolved_feed(t *testing.T) {
	mf := setupMove(t)
	defect := mf.iwhByCode(t, "DEFECT")
	mf.receive(t, nil, 5)
	open := mf.openProblem(t, defect, model.ProblemReasonSpoilage, mf.goodsProblem(1, mf.cellA, ""))
	first := mf.openProblem(t, defect, model.ProblemReasonOther, mf.goodsProblem(1, mf.cellA, ""))
	second := mf.openProblem(t, defect, model.ProblemReasonOther, mf.goodsProblem(1, mf.cellA, ""))
	for _, id := range []string{first, second} {
		if err := mf.resolve(id, model.ResolveProblemInput{Decision: model.ProblemDecisionPlace}); err != nil {
			t.Fatalf("решение: %v", err)
		}
	}
	// Время решения разводим явно: в одной секунде порядок задавал бы только id.
	for id, at := range map[string]string{first: "2026-10-20T10:00:00Z", second: "2026-10-21T10:00:00Z"} {
		_, err := mf.pool.Exec(context.Background(),
			`UPDATE warehouse_problems SET resolved_at = $2 WHERE id = $1::uuid`, id, at)
		mustNoErr(t, err)
	}

	repo := repository.NewProblemRepository(mf.pool)
	ctx := context.Background()
	page, err := repo.Resolved(ctx, model.ResolvedProblemsFilter{Limit: 1})
	mustNoErr(t, err)
	if len(page) != 1 || page[0].ID != second || page[0].Decision != model.ProblemDecisionPlace ||
		len(page[0].Items) != 1 || page[0].Items[0].CellAddress != "A" || page[0].ResolvedAt == nil {
		t.Fatalf("первая страница: %+v", page)
	}
	next, err := repo.Resolved(ctx, model.ResolvedProblemsFilter{
		BeforeResolvedAt: page[0].ResolvedAt, BeforeID: page[0].ID, Limit: 10,
	})
	mustNoErr(t, err)
	if len(next) != 1 || next[0].ID != first {
		t.Errorf("по курсору — только раньше решённая, без открытой %s: %+v", open, next)
	}

	from := time.Date(2026, 10, 21, 0, 0, 0, 0, time.UTC)
	window, err := repo.Resolved(ctx, model.ResolvedProblemsFilter{From: &from, Limit: 10})
	mustNoErr(t, err)
	if len(window) != 1 || window[0].ID != second {
		t.Errorf("окно с 21.10: %+v", window)
	}
}

// ADHOC-34: исполнение возврата в ленте — до отгрузки кто и когда отгрузил пусто, после
// сеанса на ТСД — отгрузивший и время сеанса.
func TestProblemResolved_returnShipped(t *testing.T) {
	mf := setupMove(t)
	defect := mf.iwhByCode(t, "DEFECT")
	mf.receive(t, nil, 5)
	id := mf.openProblem(t, defect, model.ProblemReasonSpoilage, mf.goodsProblem(2, mf.cellA, ""))
	mustNoErr(t, mf.resolve(id, model.ResolveProblemInput{
		Decision: model.ProblemDecisionSupplierReturn, SupplierID: mf.supplier(t, "ООО МИР"),
	}))
	repo := repository.NewProblemRepository(mf.pool)
	ctx := context.Background()

	before, err := repo.Resolved(ctx, model.ResolvedProblemsFilter{Limit: 10})
	mustNoErr(t, err)
	if len(before) != 1 || before[0].ShippedAt != nil || before[0].ShippedByName != "" || before[0].ReturnTaskNo == 0 {
		t.Fatalf("до отгрузки: %+v", before)
	}
	if _, err := mf.ship(mf.returnTask(t, id), id); err != nil {
		t.Fatalf("отгрузка: %v", err)
	}
	after, err := repo.Resolved(ctx, model.ResolvedProblemsFilter{Limit: 10})
	mustNoErr(t, err)
	if len(after) != 1 || after[0].ShippedAt == nil || after[0].ShippedByName == "" {
		t.Errorf("после отгрузки: %+v", after)
	}
}

// ADHOC-35: «Текущие» на ТСД — только открытые, свежие первыми; у короба — его состав сейчас.
func TestProblemCurrent_openOnly(t *testing.T) {
	mf := setupMove(t)
	defect := mf.iwhByCode(t, "DEFECT")
	lu := newLU(t, mf.stockFixture, model.LoadUnitBox)
	mf.receive(t, []string{lu}, 5)
	loose := mf.openProblem(t, defect, model.ProblemReasonSpoilage, mf.goodsProblem(1, mf.cellA, ""))
	box := mf.openProblem(t, defect, model.ProblemReasonBreakage, repository.ProblemSubmitInput{LoadUnitID: lu})
	done := mf.openProblem(t, defect, model.ProblemReasonOther, mf.goodsProblem(1, mf.cellA, ""))
	mustNoErr(t, mf.resolve(done, model.ResolveProblemInput{Decision: model.ProblemDecisionPlace}))
	_, err := mf.pool.Exec(context.Background(),
		`UPDATE warehouse_problems SET created_at = created_at - interval '1 hour' WHERE id = $1::uuid`, loose)
	mustNoErr(t, err)

	list, err := repository.NewProblemRepository(mf.pool).Current(context.Background())
	mustNoErr(t, err)
	if len(list) != 2 || list[0].ID != box || list[1].ID != loose {
		t.Fatalf("открытые, свежие первыми: %+v", list)
	}
	if len(list[0].Items) != 1 || list[0].Items[0].Qty != "12.000" || list[0].Status != model.ProblemStatusOpen {
		t.Errorf("короб — состав сейчас: %+v", list[0])
	}
}
