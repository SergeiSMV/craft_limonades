package service

import (
	"context"
	"errors"
	"testing"

	"craftwms/internal/model"
)

type fakeProblemReasonRepo struct {
	reasons     []model.ProblemReasonInput
	resolutions []model.ProblemResolutionInput
}

func (f *fakeProblemReasonRepo) Reasons(context.Context) ([]model.ProblemReason, error) {
	return nil, nil
}
func (f *fakeProblemReasonRepo) Resolutions(context.Context) ([]model.ProblemResolution, error) {
	return nil, nil
}
func (f *fakeProblemReasonRepo) SaveReason(_ context.Context, in model.ProblemReasonInput) (string, error) {
	f.reasons = append(f.reasons, in)
	return "c1", nil
}
func (f *fakeProblemReasonRepo) SaveResolution(_ context.Context, in model.ProblemResolutionInput) (string, error) {
	f.resolutions = append(f.resolutions, in)
	return "id", nil
}

func ptr[T any](v T) *T { return &v }

// ADHOC-55: форма причины — у новой название и хотя бы один вариант, список без повторов,
// пустым он не становится и у правки.
func TestProblemReasonService_saveReason(t *testing.T) {
	const res = "7b000000-0000-4000-8000-000000000001"
	repo := &fakeProblemReasonRepo{}
	svc := NewProblemReasonService(repo)
	ctx := context.Background()

	if _, err := svc.SaveReason(ctx, model.ProblemReasonInput{
		Name: ptr(" Недовложение "), Resolutions: &[]string{res, res},
	}); err != nil {
		t.Fatal(err)
	}
	if got := repo.reasons[0]; *got.Name != "Недовложение" || len(*got.Resolutions) != 1 {
		t.Errorf("до репозитория дошло %+v", got)
	}
	if _, err := svc.SaveReason(ctx, model.ProblemReasonInput{Code: "other", IsActive: ptr(false)}); err != nil {
		t.Errorf("правка без названия и вариантов: %v", err)
	}
	bad := []model.ProblemReasonInput{
		{Name: ptr("Без вариантов")},
		{Resolutions: &[]string{res}},
		{Name: ptr(" "), Resolutions: &[]string{res}},
		{Name: ptr("Не uuid"), Resolutions: &[]string{"x"}},
		{Code: "other", Resolutions: &[]string{}},
	}
	for _, in := range bad {
		if _, err := svc.SaveReason(ctx, in); !errors.Is(err, model.ErrInvalidProblemReason) {
			t.Errorf("%+v: %v", in, err)
		}
	}
}

// ADHOC-55: вариант — новый с названием и действием из четырёх; у правки действие не меняется.
func TestProblemReasonService_saveResolution(t *testing.T) {
	const id = "7b000000-0000-4000-8000-000000000001"
	svc := NewProblemReasonService(&fakeProblemReasonRepo{})
	ctx := context.Background()

	if _, err := svc.SaveResolution(ctx, model.ProblemResolutionInput{Name: ptr("Списать по акту"), Action: model.ProblemDecisionWriteOff}); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.SaveResolution(ctx, model.ProblemResolutionInput{ID: id, IsActive: ptr(false)}); err != nil {
		t.Errorf("выключить: %v", err)
	}
	bad := []model.ProblemResolutionInput{
		{Name: ptr("Без действия")},
		{Name: ptr("Чужое действие"), Action: "isolate"},
		{ID: id, Action: model.ProblemDecisionPlace},
		{ID: "x", Name: ptr("Не uuid")},
	}
	for _, in := range bad {
		if _, err := svc.SaveResolution(ctx, in); !errors.Is(err, model.ErrInvalidResolution) {
			t.Errorf("%+v: %v", in, err)
		}
	}
}
