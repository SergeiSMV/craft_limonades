package repository_test

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// Тесты ADHOC-31: отгрузка возврата поставщику. Фикстуры - из movement_integration_test.go
// и problem_decision_integration_test.go.

// returnTask - задание возврата, в которое легла проблема.
func (mf *moveFixture) returnTask(t *testing.T, problemID string) string {
	t.Helper()
	var id string
	mustScan(t, mf.pool, `SELECT return_task_id::text FROM warehouse_problems WHERE id = $1::uuid`, &id, problemID)
	return id
}

// ship проводит сеанс отгрузки позиций задания.
func (mf *moveFixture) ship(task string, problems ...string) (int, error) {
	return repository.ReturnSubmitForTest(context.Background(), mf.pool, repository.ReturnSubmitInput{
		ShipmentID: uuid.NewString(), TaskID: task, WarehouseID: mf.wh, CreatedBy: mf.user, ProblemIDs: problems,
	})
}

// Россыпь возврата переехала после решения - отгрузка находит её и на новом месте; позиция,
// добавленная офисом во время сеанса, оставляет задание в пуле; отгруженную второй раз и чужую
// не отгрузить; последний сеанс выполняет задание.
func TestReturnShipment_movedGoodsAndSettle(t *testing.T) {
	mf := setupMove(t)
	defect, ret := mf.iwhByCode(t, "DEFECT"), mf.iwhByCode(t, "RETURN")
	sup := mf.supplier(t, "ООО МИР")
	mf.receive(t, nil, 5)
	back := model.ResolveProblemInput{Decision: model.ProblemDecisionSupplierReturn, SupplierID: sup}

	first := mf.openProblem(t, defect, model.ProblemReasonSpoilage, mf.goodsProblem(2, mf.cellA, ""))
	mustNoErr(t, mf.resolve(first, back))
	task := mf.returnTask(t, first)
	moved := mf.goodsLine(2, mf.cellA, "", mf.cellC, "")
	moved.InternalWarehouseID = ret
	if _, err := mf.move(t, uuid.NewString(), moved); err != nil {
		t.Fatalf("перенос возврата: %v", err)
	}
	second := mf.openProblem(t, defect, model.ProblemReasonExpired, mf.goodsProblem(1, mf.cellA, ""))
	mustNoErr(t, mf.resolve(second, back))
	if mf.returnTask(t, second) != task {
		t.Fatal("второй возврат того же поставщика - не в открытом задании")
	}

	if n, err := mf.ship(task, first); err != nil || n != 1 {
		t.Fatalf("отгрузка первой позиции: %d %v", n, err)
	}
	// Товар одной партии на складе возврата неразличим: отгрузка, как и место позиции на ТСД,
	// начинает с ячейки, куда товар положило решение (A - там уже возврат второй проблемы),
	// и добирает недостающее по адресам (C).
	if c, a := mf.qtyIn(t, mf.cellC, ret), mf.qtyIn(t, mf.cellA, ret); c != "1" || a != "0" {
		t.Errorf("возврат C %s, A %s; ожидалось 1 и 0", c, a)
	}
	var status string
	mustScan(t, mf.pool, `SELECT status FROM warehouse_tasks WHERE id = $1::uuid`, &status, task)
	if status != "new" {
		t.Errorf("задание с неотгруженной позицией: %s", status)
	}
	if _, err := mf.ship(task, first); !errors.Is(err, repository.ErrNotInTask) {
		t.Errorf("повторная отгрузка позиции: %v", err)
	}
	if _, err := mf.ship(task, uuid.NewString()); !errors.Is(err, repository.ErrNotInTask) {
		t.Errorf("чужая позиция: %v", err)
	}
	if _, err := mf.ship(task, second); err != nil {
		t.Fatalf("отгрузка второй позиции: %v", err)
	}
	mustScan(t, mf.pool, `SELECT status FROM warehouse_tasks WHERE id = $1::uuid`, &status, task)
	if status != "done" {
		t.Errorf("задание после последней позиции: %s", status)
	}
	if _, err := mf.ship(task, second); !errors.Is(err, repository.ErrTaskDone) {
		t.Errorf("сеанс по выполненному заданию: %v", err)
	}
}
