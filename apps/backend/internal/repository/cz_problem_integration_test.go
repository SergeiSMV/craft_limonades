package repository_test

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/google/uuid"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// Тесты CZ-06: марки ЧЗ в проблемах склада, решении офиса и отгрузке возврата (долг 30).
// Фикстура setupCZMove — из cz_movement_integration_test.go.

// markProblem — товар фикстуры с марками: количество — их число.
func (cf *czMoveFixture) markProblem(cell, fromLU string, marks ...string) repository.ProblemSubmitInput {
	in := cf.goodsProblem(int64(len(marks)), cell, fromLU)
	in.Marks = marks
	return in
}

// markState — статус, ячейка и склад марки: «in_stock <ячейка> <склад>».
func (cf *czMoveFixture) markState(t *testing.T, cis string) string {
	t.Helper()
	var s string
	mustScan(t, cf.pool, `
		SELECT status || ' ' || COALESCE(cell_id::text, '-') || ' ' || COALESCE(internal_warehouse_id::text, '-')
		FROM cz_marks WHERE cis = $1`, &s, cis)
	return s
}

// shipMarks проводит сеанс отгрузки возврата с отсканированными марками.
func (cf *czMoveFixture) shipMarks(task string, problems []string, marks ...string) (int, error) {
	return repository.ReturnSubmitForTest(context.Background(), cf.pool, repository.ReturnSubmitInput{
		ShipmentID: uuid.NewString(), TaskID: task, WarehouseID: cf.wh, CreatedBy: cf.user,
		ProblemIDs: problems, Marks: marks,
	})
}

// Пометка маркируемого товара — только марками: марки уходят в россыпь склада назначения
// той же ячейки и запоминают проблему; марка из короба ЧЗ вскрывает его.
func TestCZProblem_marksGoToProblem(t *testing.T) {
	cf := setupCZMove(t)
	defect := cf.iwhByCode(t, "DEFECT")

	err := cf.problem(t, defect, cf.goodsProblem(1, cf.cellA, ""))
	if !errors.Is(err, model.ErrCZMarksRequired) || !strings.Contains(err.Error(), "только сканом марок") {
		t.Fatalf("пометка без марок: %v", err)
	}
	if err := cf.problem(t, defect, cf.markProblem(cf.cellA, "", czB1)); !errors.Is(err, model.ErrCZMarkNotAtSource) {
		t.Errorf("марка короба как россыпь: %v", err)
	}

	loose := cf.openProblem(t, defect, model.ProblemReasonBreakage, cf.markProblem(cf.cellA, "", czLoose[0], czLoose[1]))
	fromBox := cf.openProblem(t, defect, model.ProblemReasonBreakage, cf.markProblem("", cf.boxA, czB1))

	want := "in_stock " + cf.cellA + " " + defect
	for _, cis := range []string{czLoose[0], czLoose[1], czB1} {
		if got := cf.markState(t, cis); got != want {
			t.Errorf("марка %s: %s, ожидалось %s", cis, got, want)
		}
	}
	var links string
	mustScan(t, cf.pool, `SELECT string_agg(problem_id::text, ',' ORDER BY cis) FROM cz_marks WHERE cis = ANY($1)`,
		&links, []string{czLoose[0], czLoose[1], czB1})
	if links != fromBox+","+loose+","+loose {
		t.Errorf("проблемы марок: %s", links)
	}
	if !cf.opened(t, czBox) {
		t.Error("марка вынута из короба ЧЗ проблемой — короб не вскрыт")
	}
	if got := cf.markState(t, czLoose[2]); got != "in_stock "+cf.cellA+" "+cf.iwh {
		t.Errorf("непомеченная марка: %s", got)
	}
}

// Решение офиса берёт ровно марки проблемы там, где они лежат: «списать» уводит их со склада,
// «разместить» возвращает на «Основной».
func TestCZProblemResolve_byMarks(t *testing.T) {
	cf := setupCZMove(t)
	defect := cf.iwhByCode(t, "DEFECT")
	spoiled := cf.openProblem(t, defect, model.ProblemReasonSpoilage, cf.markProblem(cf.cellA, "", czLoose[0], czLoose[1]))
	other := cf.openProblem(t, defect, model.ProblemReasonOther, cf.markProblem(cf.cellA, "", czLoose[2]))

	// Одна марка брака переехала в C.
	moved := cf.markLine(cf.cellA, "", cf.cellC, "", czLoose[1])
	moved.InternalWarehouseID = defect
	if _, err := cf.move(t, uuid.NewString(), moved); err != nil {
		t.Fatalf("перенос брака марками: %v", err)
	}

	if err := cf.resolve(spoiled, model.ResolveProblemInput{
		Decision: model.ProblemDecisionWriteOff, DocNumber: "СП-1", DocDate: "2026-10-25",
	}); err != nil {
		t.Fatalf("списание: %v", err)
	}
	var lines string
	mustScan(t, cf.pool, `
		SELECT string_agg(c.address || ':' || l.qty::text, ',' ORDER BY l.line_no)
		FROM warehouse_problem_lines l JOIN cells c ON c.id = l.cell_id WHERE l.problem_id = $1::uuid`,
		&lines, spoiled)
	if lines != "A:1.000,C:1.000" {
		t.Errorf("строки решения: %s, ожидались A:1 и C:1 — там, где марки", lines)
	}
	for _, cis := range czLoose[:2] {
		if got := cf.markState(t, cis); got != "written_off - -" {
			t.Errorf("списанная марка %s: %s", cis, got)
		}
	}
	if d := cf.qtyIn(t, cf.cellA, defect); d != "1" {
		t.Errorf("брак в A: %s, ожидалось 1 (марка второй проблемы)", d)
	}

	if err := cf.resolve(other, model.ResolveProblemInput{Decision: model.ProblemDecisionPlace}); err != nil {
		t.Fatalf("разместить: %v", err)
	}
	if got := cf.markState(t, czLoose[2]); got != "in_stock "+cf.cellA+" "+cf.iwh {
		t.Errorf("размещённая марка: %s", got)
	}
}

// Долг 30: позиция возврата россыпью уезжает, только когда названы все её марки; лишняя
// марка — отказ сеанса; отгруженные марки — «возвращена». Короб — по-прежнему одним сканом.
func TestCZReturnShipment_allMarksOfPosition(t *testing.T) {
	cf := setupCZMove(t)
	defect, ret := cf.iwhByCode(t, "DEFECT"), cf.iwhByCode(t, "RETURN")
	sup := cf.supplier(t, "ООО МИР")
	back := model.ResolveProblemInput{Decision: model.ProblemDecisionSupplierReturn, SupplierID: sup}

	loose := cf.openProblem(t, defect, model.ProblemReasonExpired, cf.markProblem(cf.cellA, "", czLoose[0], czLoose[1]))
	box := cf.openProblem(t, defect, model.ProblemReasonExpired, repository.ProblemSubmitInput{LoadUnitID: cf.boxA})
	mustNoErr(t, cf.resolve(loose, back))
	mustNoErr(t, cf.resolve(box, back))
	task := cf.returnTask(t, loose)
	if got := cf.markState(t, czLoose[0]); got != "in_stock "+cf.cellA+" "+ret {
		t.Errorf("марка после решения «возврат»: %s", got)
	}

	// ТСД видит марки позиции россыпью и код короба ЧЗ — для скана без связи.
	current, err := repository.NewTaskRepository(cf.pool).Current(context.Background(), cf.user, 0)
	mustNoErr(t, err)
	seen := false
	for _, tk := range current {
		if tk.ID != task {
			continue
		}
		seen = true
		for _, it := range tk.Items {
			switch {
			case it.LoadUnitID != nil && (it.CZCode == nil || *it.CZCode != czBox || len(it.Marks) != 0):
				t.Errorf("позиция-короб: %+v", it)
			case it.LoadUnitID == nil && len(it.Marks) != 2:
				t.Errorf("марки позиции россыпью: %v", it.Marks)
			}
		}
	}
	if !seen {
		t.Fatal("ТСД не видит задание возврата")
	}

	both := []string{loose, box}
	if _, err := cf.shipMarks(task, both); !errors.Is(err, model.ErrCZReturnMarksIncomplete) {
		t.Errorf("без марок: %v", err)
	}
	_, err = cf.shipMarks(task, both, czLoose[0])
	if !errors.Is(err, model.ErrCZReturnMarksIncomplete) || !strings.HasPrefix(err.Error(), "Отсканированы не все марки") {
		t.Errorf("одна марка из двух: %v", err)
	}
	if _, err := cf.shipMarks(task, both, czLoose[0], czLoose[1], czLoose[2]); !errors.Is(err, model.ErrCZReturnMarkForeign) {
		t.Errorf("лишняя марка: %v", err)
	}
	if n, err := cf.shipMarks(task, both, czLoose[1], czLoose[0]); err != nil || n != 2 {
		t.Fatalf("отгрузка всеми марками: %d %v", n, err)
	}
	for _, cis := range []string{czLoose[0], czLoose[1], czG1, czB1} {
		if got := cf.markState(t, cis); got != "returned - -" {
			t.Errorf("отгруженная марка %s: %s", cis, got)
		}
	}
	if got := cf.markState(t, czLoose[2]); got != "in_stock "+cf.cellA+" "+cf.iwh {
		t.Errorf("марка вне возврата: %s", got)
	}
}
