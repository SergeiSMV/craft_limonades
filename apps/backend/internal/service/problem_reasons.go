package service

import (
	"context"
	"slices"
	"strings"
	"unicode/utf8"

	"craftwms/internal/model"
)

// problemReasonNameMax — предел названия причины и варианта в символах.
const problemReasonNameMax = 100

// problemReasonRepo — зависимость сервиса справочника причин.
type problemReasonRepo interface {
	Reasons(ctx context.Context) ([]model.ProblemReason, error)
	Resolutions(ctx context.Context) ([]model.ProblemResolution, error)
	SaveReason(ctx context.Context, in model.ProblemReasonInput) (string, error)
	SaveResolution(ctx context.Context, in model.ProblemResolutionInput) (string, error)
}

// ProblemReasonService — справочник причин проблем склада и вариантов решения (ADHOC-55): ТСД
// читает причины для пометки, портал ведёт и то и другое. Удаления нет — только «неактивен».
type ProblemReasonService struct {
	repo problemReasonRepo
}

// NewProblemReasonService создаёт сервис справочника причин.
func NewProblemReasonService(repo problemReasonRepo) *ProblemReasonService {
	return &ProblemReasonService{repo: repo}
}

// Reasons — все причины, и неактивные: ТСД подписывает ими и старые проблемы.
func (s *ProblemReasonService) Reasons(ctx context.Context) ([]model.ProblemReason, error) {
	return s.repo.Reasons(ctx)
}

// Resolutions — все варианты решения, и неактивные.
func (s *ProblemReasonService) Resolutions(ctx context.Context) ([]model.ProblemResolution, error) {
	return s.repo.Resolutions(ctx)
}

// SaveReason проверяет форму причины и записывает её; возвращает код.
//
// У новой причины обязательны название и хотя бы один вариант; у правки — только то, что
// передано, но пустым список вариантов не становится: решить такую проблему было бы нечем.
func (s *ProblemReasonService) SaveReason(ctx context.Context, in model.ProblemReasonInput) (string, error) {
	in.Code = strings.TrimSpace(in.Code)
	if in.Name != nil {
		name := strings.TrimSpace(*in.Name)
		if !validReasonName(name) {
			return "", model.ErrInvalidProblemReason
		}
		in.Name = &name
	}
	if in.Code == "" && (in.Name == nil || in.Resolutions == nil) {
		return "", model.ErrInvalidProblemReason
	}
	if in.Resolutions != nil {
		ids := []string{}
		for _, id := range *in.Resolutions {
			id = strings.TrimSpace(id)
			if !isUUID(id) {
				return "", model.ErrInvalidProblemReason
			}
			if !slices.Contains(ids, id) {
				ids = append(ids, id)
			}
		}
		if len(ids) == 0 {
			return "", model.ErrInvalidProblemReason
		}
		in.Resolutions = &ids
	}
	return s.repo.SaveReason(ctx, in)
}

// SaveResolution проверяет форму варианта и записывает его; возвращает id. Новому варианту
// нужны название и действие из четырёх; у правки действие не меняется.
func (s *ProblemReasonService) SaveResolution(ctx context.Context, in model.ProblemResolutionInput) (string, error) {
	in.ID = strings.TrimSpace(in.ID)
	in.Action = strings.TrimSpace(in.Action)
	if in.Name != nil {
		name := strings.TrimSpace(*in.Name)
		if !validReasonName(name) {
			return "", model.ErrInvalidResolution
		}
		in.Name = &name
	}
	if in.ID == "" {
		if in.Name == nil || !slices.Contains(model.ProblemDecisions, in.Action) {
			return "", model.ErrInvalidResolution
		}
	} else if !isUUID(in.ID) || in.Action != "" {
		return "", model.ErrInvalidResolution
	}
	return s.repo.SaveResolution(ctx, in)
}

func validReasonName(name string) bool {
	return name != "" && utf8.RuneCountInString(name) <= problemReasonNameMax
}
