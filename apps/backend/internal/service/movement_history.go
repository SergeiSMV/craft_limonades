package service

import (
	"context"
	"strings"

	"craftwms/internal/model"
)

// Пределы страницы ленты истории перемещений - как у «Завершённых» заданий.
const (
	movementHistoryDefaultLimit = 30
	movementHistoryMaxLimit     = 100
)

// movementHistoryRepo - зависимость сервиса истории перемещений.
type movementHistoryRepo interface {
	List(ctx context.Context, f model.MovementHistoryFilter) ([]model.MovementRecord, error)
	Executors(ctx context.Context) ([]model.TaskUser, error)
	Get(ctx context.Context, id string) (model.MovementRecordDetail, error)
}

// MovementHistoryService - история перемещений всего склада для ТСД (ADHOC-28): лента
// с фильтром по периоду и исполнителю, запись со строками. Только онлайн, только чтение.
type MovementHistoryService struct {
	repo movementHistoryRepo
}

// NewMovementHistoryService создаёт сервис истории перемещений.
func NewMovementHistoryService(repo movementHistoryRepo) *MovementHistoryService {
	return &MovementHistoryService{repo: repo}
}

// MovementHistoryQuery - фильтр ленты в транспортном виде, как его шлёт ТСД: даты
// 'YYYY-MM-DD' по времени склада, курсор - момент проведения (RFC3339) и id последней записи.
type MovementHistoryQuery struct {
	From, To       string
	ExecutorID     string
	BeforePostedAt string
	BeforeID       string
	Limit          int
}

// List - страница ленты по фильтру.
func (s *MovementHistoryService) List(ctx context.Context, q MovementHistoryQuery) ([]model.MovementRecord, error) {
	w, err := parseFeedWindow(q.From, q.To, q.BeforePostedAt, q.BeforeID, q.Limit,
		movementHistoryDefaultLimit, movementHistoryMaxLimit)
	if err != nil {
		return nil, model.ErrInvalidMovementFilter
	}
	f := model.MovementHistoryFilter{
		From: w.From, To: w.To,
		ExecutorID:     strings.TrimSpace(q.ExecutorID),
		BeforePostedAt: w.Before,
		BeforeID:       w.BeforeID,
		Limit:          w.Limit,
	}
	if !isOptionalUUID(f.ExecutorID) {
		return nil, model.ErrInvalidMovementFilter
	}
	return s.repo.List(ctx, f)
}

// Executors - варианты фильтра ленты по исполнителю.
func (s *MovementHistoryService) Executors(ctx context.Context) ([]model.TaskUser, error) {
	return s.repo.Executors(ctx)
}

// Get - запись со строками. Не UUID - «не найдено»: такой записи заведомо нет.
func (s *MovementHistoryService) Get(ctx context.Context, id string) (model.MovementRecordDetail, error) {
	if !isUUID(strings.TrimSpace(id)) {
		return model.MovementRecordDetail{}, model.ErrMovementNotFound
	}
	return s.repo.Get(ctx, strings.TrimSpace(id))
}
