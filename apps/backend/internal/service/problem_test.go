package service

import (
	"context"
	"errors"
	"testing"

	"craftwms/internal/model"
)

type fakeProblemRepo struct {
	resolved []model.ResolveProblemInput
	feed     []model.ResolvedProblemsFilter
}

func (f *fakeProblemRepo) List(context.Context, model.ProblemFilter) ([]model.Problem, error) {
	return nil, nil
}
func (f *fakeProblemRepo) Resolved(_ context.Context, fl model.ResolvedProblemsFilter) ([]model.Problem, error) {
	f.feed = append(f.feed, fl)
	return nil, nil
}
func (f *fakeProblemRepo) Resolve(_ context.Context, in model.ResolveProblemInput) error {
	f.resolved = append(f.resolved, in)
	return nil
}

// P6-07-3: форма решения проверяется до базы — у списания документ 1С, у возврата поставщик,
// чужие поля и неизвестное решение отклоняются.
func TestProblemService_resolveValidation(t *testing.T) {
	const id = "8f4c2b1e-0d3a-4c5b-9e6f-1a2b3c4d5e6f"
	repo := &fakeProblemRepo{}
	svc := NewProblemService(repo)
	ctx := context.Background()

	ok := []model.ResolveProblemInput{
		{ProblemID: id, Decision: model.ProblemDecisionWriteOff, DocNumber: " СП-1 ", DocDate: "2026-10-21"},
		{ProblemID: id, Decision: model.ProblemDecisionPlace},
		{ProblemID: id, Decision: model.ProblemDecisionSupplierReturn, SupplierID: id},
	}
	for _, in := range ok {
		if err := svc.Resolve(ctx, in); err != nil {
			t.Errorf("%s: %v", in.Decision, err)
		}
	}
	if repo.resolved[0].DocNumber != "СП-1" {
		t.Errorf("номер документа не обрезан: %q", repo.resolved[0].DocNumber)
	}

	bad := []model.ResolveProblemInput{
		{ProblemID: id, Decision: "isolate"},
		{ProblemID: id, Decision: model.ProblemDecisionWriteOff, DocDate: "2026-10-21"},
		{ProblemID: id, Decision: model.ProblemDecisionWriteOff, DocNumber: "1", DocDate: "21.10.2026"},
		{ProblemID: id, Decision: model.ProblemDecisionPlace, DocNumber: "1"},
		{ProblemID: id, Decision: model.ProblemDecisionPlace, SupplierID: id},
		{ProblemID: id, Decision: model.ProblemDecisionSupplierReturn},
	}
	for _, in := range bad {
		if err := svc.Resolve(ctx, in); !errors.Is(err, ErrInvalidDecision) {
			t.Errorf("%+v: %v", in, err)
		}
	}
	if err := svc.Resolve(ctx, model.ResolveProblemInput{ProblemID: "x", Decision: model.ProblemDecisionPlace}); !errors.Is(err, ErrInvalidProblemID) {
		t.Errorf("не UUID: %v", err)
	}
	if len(repo.resolved) != len(ok) {
		t.Errorf("до репозитория дошло %d решений, ожидалось %d", len(repo.resolved), len(ok))
	}
}

// Таблица решений по причинам (решение 2026-10-21).
func TestProblemDecisionsFor(t *testing.T) {
	cases := map[string]int{
		model.ProblemReasonBreakage: 1, model.ProblemReasonSpoilage: 2, model.ProblemReasonExpired: 2,
		model.ProblemReasonForeignMark: 2, model.ProblemReasonOther: 3, "unknown": 0,
	}
	for reason, n := range cases {
		if got := model.ProblemDecisionsFor(reason); len(got) != n {
			t.Errorf("%s: %v", reason, got)
		}
	}
}

// ADHOC-34: лента решённых на ТСД — окно дат по складу (to включительно), курсор только с id,
// предел страницы.
func TestProblemService_resolvedFeed(t *testing.T) {
	repo := &fakeProblemRepo{}
	svc := NewProblemService(repo)
	ctx := context.Background()

	if _, err := svc.Resolved(ctx, ResolvedQuery{From: "2026-10-01", To: "2026-10-21", Limit: 1000}); err != nil {
		t.Fatal(err)
	}
	f := repo.feed[0]
	if f.Limit != resolvedProblemsMaxLimit {
		t.Errorf("предел страницы: %d", f.Limit)
	}
	if f.To == nil || f.To.Format("2006-01-02") != "2026-10-22" {
		t.Errorf("to включается целиком: %v", f.To)
	}
	if _, err := svc.Resolved(ctx, ResolvedQuery{}); err != nil || repo.feed[1].Limit != resolvedProblemsDefaultLimit {
		t.Errorf("без фильтра: %v, предел %d", err, repo.feed[1].Limit)
	}
	bad := []ResolvedQuery{
		{From: "21.10.2026"},
		{BeforeResolvedAt: "2026-10-21T10:00:00Z"},
		{BeforeResolvedAt: "2026-10-21T10:00:00Z", BeforeID: "не-uuid"},
	}
	for _, q := range bad {
		if _, err := svc.Resolved(ctx, q); !errors.Is(err, ErrInvalidProblemFilter) {
			t.Errorf("%+v: ждали ErrInvalidProblemFilter, получили %v", q, err)
		}
	}
}
