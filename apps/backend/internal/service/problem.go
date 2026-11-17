package service

import (
	"context"
	"errors"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"craftwms/internal/model"
)

// ErrInvalidDecision - решение по проблеме составлено неверно: неизвестное решение, нет
// документа списания или поставщика возврата, лишние поля другого решения.
var ErrInvalidDecision = errors.New("invalid problem decision")

// ErrInvalidProblemFilter - фильтр ленты решённых проблем неверен: дата не ISO, курсор без id.
var ErrInvalidProblemFilter = errors.New("invalid resolved problems filter")

// problemDocNumberMax - предел номера документа 1С в символах.
const problemDocNumberMax = 50

// Страница ленты решённых проблем на ТСД (ADHOC-34) - как у «Завершённых» заданий.
const (
	resolvedProblemsDefaultLimit = 30
	resolvedProblemsMaxLimit     = 100
)

// problemRepo - зависимость сервиса проблем склада.
type problemRepo interface {
	List(ctx context.Context, f model.ProblemFilter) ([]model.Problem, error)
	Resolved(ctx context.Context, f model.ResolvedProblemsFilter) ([]model.Problem, error)
	Current(ctx context.Context) ([]model.Problem, error)
	Resolve(ctx context.Context, in model.ResolveProblemInput) error
	Resolution(ctx context.Context, id string) (model.ProblemResolution, error)
}

// ProblemService - «Проблемы склада» в портале (P6-07-3): рабочий список офиса и решение по
// проблеме - списать по документу 1С, разместить в «Основной» или вернуть поставщику.
type ProblemService struct {
	repo problemRepo
}

// NewProblemService создаёт сервис проблем склада.
func NewProblemService(repo problemRepo) *ProblemService {
	return &ProblemService{repo: repo}
}

// List - рабочий список: open / resolved / пусто - все.
func (s *ProblemService) List(ctx context.Context, status string) ([]model.Problem, error) {
	if status != "" && status != model.ProblemStatusOpen && status != model.ProblemStatusResolved {
		return nil, ErrInvalidDecision
	}
	return s.repo.List(ctx, model.ProblemFilter{Status: status})
}

// Current - открытые проблемы всего склада для ТСД (ADHOC-35): вкладка «Текущие».
func (s *ProblemService) Current(ctx context.Context) ([]model.Problem, error) {
	return s.repo.Current(ctx)
}

// ResolvedQuery - фильтр ленты решённых проблем в транспортном виде, как его шлёт ТСД: даты
// 'YYYY-MM-DD' по времени склада (`to` включается целиком), курсор - время решения (RFC3339)
// и id последней показанной записи.
type ResolvedQuery struct {
	From, To         string
	BeforeResolvedAt string
	BeforeID         string
	Limit            int
}

// Resolved - страница ленты «Завершённые» проблем на ТСД (ADHOC-34): только решённые офисом,
// все по складу, свежие решения первыми.
func (s *ProblemService) Resolved(ctx context.Context, q ResolvedQuery) ([]model.Problem, error) {
	w, err := parseFeedWindow(q.From, q.To, q.BeforeResolvedAt, q.BeforeID, q.Limit,
		resolvedProblemsDefaultLimit, resolvedProblemsMaxLimit)
	if err != nil {
		return nil, ErrInvalidProblemFilter
	}
	return s.repo.Resolved(ctx, model.ResolvedProblemsFilter{
		From: w.From, To: w.To, BeforeResolvedAt: w.Before, BeforeID: w.BeforeID, Limit: w.Limit,
	})
}

// Resolve проверяет форму решения и проводит его.
//
// Решение - вариант справочника (ADHOC-55): его действие определяет форму. Прежний клиент шлёт
// одно действие без варианта - форма проверяется по нему. Дальше всё, что проверяется без
// записи проблемы: идентификаторы, у списания и пересорта - номер и дата документа 1С (дата -
// ISO), у возврата - поставщик. Поля чужого решения - противоречие, а не подсказка.
// Допустимость варианта при причине проверяет репозиторий: причину знает только запись.
func (s *ProblemService) Resolve(ctx context.Context, in model.ResolveProblemInput) error {
	in.Decision = strings.TrimSpace(in.Decision)
	in.DocNumber = strings.TrimSpace(in.DocNumber)
	in.DocDate = strings.TrimSpace(in.DocDate)
	in.SupplierID = strings.TrimSpace(in.SupplierID)
	in.ResolutionID = strings.TrimSpace(in.ResolutionID)
	if !isUUID(in.ProblemID) {
		return ErrInvalidProblemID
	}
	if in.ResolutionID != "" {
		if !isUUID(in.ResolutionID) {
			return ErrInvalidDecision
		}
		res, err := s.repo.Resolution(ctx, in.ResolutionID)
		if errors.Is(err, model.ErrResolutionNotFound) {
			return ErrInvalidDecision
		}
		if err != nil {
			return err
		}
		if in.Decision != "" && in.Decision != res.Action {
			return ErrInvalidDecision
		}
		in.Decision = res.Action
	}
	if !slices.Contains(model.ProblemDecisions, in.Decision) {
		return ErrInvalidDecision
	}

	// Документ 1С - у списания и у пересорта (ADHOC-53): документ пересортицы.
	withDoc := in.Decision == model.ProblemDecisionWriteOff || in.Decision == model.ProblemDecisionRegrade
	if withDoc {
		if in.DocNumber == "" || utf8.RuneCountInString(in.DocNumber) > problemDocNumberMax {
			return ErrInvalidDecision
		}
		if _, err := time.Parse(dateLayoutISO, in.DocDate); err != nil {
			return ErrInvalidDecision
		}
	} else if in.DocNumber != "" || in.DocDate != "" {
		return ErrInvalidDecision
	}

	if in.Decision == model.ProblemDecisionSupplierReturn {
		if !isUUID(in.SupplierID) {
			return ErrInvalidDecision
		}
	} else if in.SupplierID != "" {
		return ErrInvalidDecision
	}
	return s.repo.Resolve(ctx, in)
}
