package repository_test

import (
	"context"
	"errors"
	"testing"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// Тесты ADHOC-55: справочник причин проблем и вариантов решения. Фикстура setupMove - из
// movement_integration_test.go, пометка и решение - из problem_integration_test.go и
// problem_decision_integration_test.go.

// Постоянные id вариантов, заведённых миграцией 39.
const (
	resolutionWriteOff = "7b000000-0000-4000-8000-000000000001"
	resolutionPlace    = "7b000000-0000-4000-8000-000000000002"
	resolutionRegrade  = "7b000000-0000-4000-8000-000000000004"
)

func ptr[T any](v T) *T { return &v }

// Новая причина из портала: кладовщик помечает ею товар, комментарий - по её флагу; выключенная
// всё равно принимается из очереди; решение - только её вариантами, и вариант записывается.
func TestProblemReasons_customReason(t *testing.T) {
	mf := setupMove(t)
	ctx := context.Background()
	repo := repository.NewProblemReasonRepository(mf.pool)
	defect := mf.iwhByCode(t, "DEFECT")
	mf.receive(t, nil, 5) // A: россыпь 5

	code, err := repo.SaveReason(ctx, model.ProblemReasonInput{
		Name: ptr("Недовложение"), CommentRequired: ptr(true), Resolutions: &[]string{resolutionPlace}, By: mf.user,
	})
	if err != nil {
		t.Fatalf("завести причину: %v", err)
	}
	if code == "" || code == model.ProblemReasonOther {
		t.Fatalf("код новой причины: %q", code)
	}

	in := mf.goodsProblem(1, mf.cellA, "")
	in.Reason = code
	if err := mf.problem(t, defect, in); !errors.Is(err, model.ErrProblemCommentRequired) {
		t.Errorf("без комментария: %v, ожидалась ErrProblemCommentRequired", err)
	}
	// Офис выключил причину, пока операция ждала в очереди ТСД, - пометка всё равно проходит.
	if _, err := repo.SaveReason(ctx, model.ProblemReasonInput{Code: code, IsActive: ptr(false), By: mf.user}); err != nil {
		t.Fatalf("выключить причину: %v", err)
	}
	in.Comment = "не хватает двух бутылок"
	id := mf.openProblem(t, defect, code, in)

	if err := mf.resolve(id, model.ResolveProblemInput{
		ResolutionID: resolutionWriteOff, Decision: model.ProblemDecisionWriteOff, DocNumber: "СП-1", DocDate: "2026-10-29",
	}); !errors.Is(err, model.ErrDecisionNotAllowed) {
		t.Errorf("вариант не причины: %v, ожидалась ErrDecisionNotAllowed", err)
	}
	if err := mf.resolve(id, model.ResolveProblemInput{
		ResolutionID: resolutionPlace, Decision: model.ProblemDecisionPlace,
	}); err != nil {
		t.Fatalf("разместить: %v", err)
	}
	var got string
	mustScan(t, mf.pool, `SELECT resolution_id::text || ' ' || decision FROM warehouse_problems WHERE id = $1::uuid`, &got, id)
	if got != resolutionPlace+" place" {
		t.Errorf("записанное решение: %q", got)
	}
}

// Прежний клиент решает одним действием - берётся первый активный вариант причины с ним;
// выключенный вариант не годится ни так, ни по id.
func TestProblemReasons_decisionWithoutResolution(t *testing.T) {
	mf := setupMove(t)
	ctx := context.Background()
	repo := repository.NewProblemReasonRepository(mf.pool)
	defect := mf.iwhByCode(t, "DEFECT")
	mf.receive(t, nil, 5)

	id := mf.openProblem(t, defect, model.ProblemReasonOther, mf.goodsProblem(1, mf.cellA, ""))
	if _, err := repo.SaveResolution(ctx, model.ProblemResolutionInput{ID: resolutionPlace, IsActive: ptr(false), By: mf.user}); err != nil {
		t.Fatalf("выключить вариант: %v", err)
	}
	if err := mf.resolve(id, model.ResolveProblemInput{Decision: model.ProblemDecisionPlace}); !errors.Is(err, model.ErrDecisionNotAllowed) {
		t.Errorf("выключенный вариант действием: %v", err)
	}
	if err := mf.resolve(id, model.ResolveProblemInput{
		Decision: model.ProblemDecisionWriteOff, DocNumber: "СП-2", DocDate: "2026-10-29",
	}); err != nil {
		t.Fatalf("списать действием: %v", err)
	}
	var got string
	mustScan(t, mf.pool, `SELECT resolution_id::text FROM warehouse_problems WHERE id = $1::uuid`, &got, id)
	if got != resolutionWriteOff {
		t.Errorf("вариант по действию: %q", got)
	}
}

// Жёсткие правила справочника: системную причину не выключить, «пересорт» - только у
// «Пересорт» и у него - только «пересорт», название не повторяется, причину программы
// кладовщик не ставит.
func TestProblemReasons_rules(t *testing.T) {
	mf := setupMove(t)
	ctx := context.Background()
	repo := repository.NewProblemReasonRepository(mf.pool)

	if _, err := repo.SaveReason(ctx, model.ProblemReasonInput{
		Code: model.ProblemReasonForeignMark, IsActive: ptr(false), By: mf.user,
	}); !errors.Is(err, model.ErrProblemReasonSystem) {
		t.Errorf("выключить системную: %v", err)
	}
	if _, err := repo.SaveReason(ctx, model.ProblemReasonInput{
		Name: ptr("Странное"), Resolutions: &[]string{resolutionRegrade}, By: mf.user,
	}); !errors.Is(err, model.ErrResolutionRegradeMismatch) {
		t.Errorf("пересорт у чужой причины: %v", err)
	}
	if _, err := repo.SaveReason(ctx, model.ProblemReasonInput{
		Code: model.ProblemReasonRegrade, Resolutions: &[]string{resolutionWriteOff}, By: mf.user,
	}); !errors.Is(err, model.ErrResolutionRegradeMismatch) {
		t.Errorf("списание у пересорта: %v", err)
	}
	if _, err := repo.SaveReason(ctx, model.ProblemReasonInput{
		Name: ptr("бой"), Resolutions: &[]string{resolutionWriteOff}, By: mf.user,
	}); !errors.Is(err, model.ErrProblemReasonNameTaken) {
		t.Errorf("повтор названия: %v", err)
	}
	if _, err := repo.SaveResolution(ctx, model.ProblemResolutionInput{
		Name: ptr("списать"), Action: model.ProblemDecisionWriteOff, By: mf.user,
	}); !errors.Is(err, model.ErrResolutionNameTaken) {
		t.Errorf("повтор названия варианта: %v", err)
	}

	// Переименование системной причины видно в списке; пересорт остался при своём варианте.
	if _, err := repo.SaveReason(ctx, model.ProblemReasonInput{
		Code: model.ProblemReasonNotFound, Name: ptr("Не нашли при пересчёте"), By: mf.user,
	}); err != nil {
		t.Fatalf("переименовать системную: %v", err)
	}
	reasons, err := repo.Reasons(ctx)
	mustNoErr(t, err)
	for _, r := range reasons {
		if r.Code == model.ProblemReasonNotFound && r.Name != "Не нашли при пересчёте" {
			t.Errorf("название после правки: %q", r.Name)
		}
		if r.Code == model.ProblemReasonRegrade && (len(r.Resolutions) != 1 || r.Resolutions[0] != resolutionRegrade) {
			t.Errorf("варианты пересорта: %v", r.Resolutions)
		}
	}

	defect := mf.iwhByCode(t, "DEFECT")
	mf.receive(t, nil, 5)
	in := mf.goodsProblem(1, mf.cellA, "")
	in.Reason = model.ProblemReasonRetired
	if err := mf.problem(t, defect, in); !errors.Is(err, model.ErrUnknownReason) {
		t.Errorf("выбытие марки с ТСД: %v, ожидалась ErrUnknownReason", err)
	}
}
