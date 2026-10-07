package service

import (
	"context"
	"errors"
	"strings"
	"time"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// TaskStaleAfter — через сколько без отправок взятое задание снова видно всем (решение
// 2026-10-07): кладовщик мог уйти со смены или разрядить терминал, и задание не должно застрять.
// Снимать задание вручную будет портал (P8-03-01); этот срок — страховка до него и вместе с ним.
const TaskStaleAfter = 8 * time.Hour

// Пределы страницы ленты «Завершённые».
const (
	completedDefaultLimit = 30
	completedMaxLimit     = 100
)

// Ошибки входа заданий.
var (
	// ErrInvalidTaskFilter — фильтр ленты не разобран (дата, курсор, исполнитель).
	ErrInvalidTaskFilter = errors.New("invalid completed tasks filter")
)

// taskRepo — зависимость сервиса заданий (интерфейс ради тестируемости).
type taskRepo interface {
	Current(ctx context.Context, userID string, staleAfter time.Duration) ([]model.Task, error)
	ByID(ctx context.Context, id, userID string) (model.Task, error)
	Sessions(ctx context.Context, taskID string) ([]model.TaskSession, error)
	Take(ctx context.Context, id, userID string, staleAfter time.Duration) error
	Release(ctx context.Context, id, userID string) error
	Completed(ctx context.Context, f model.CompletedTasksFilter) ([]model.CompletedTask, error)
	Executors(ctx context.Context) ([]model.TaskUser, error)
}

// TaskService — задания для склада на ТСД (P5-02-1): текущие, взятие, лента завершённых.
type TaskService struct {
	repo taskRepo
}

// NewTaskService создаёт сервис заданий.
func NewTaskService(repo taskRepo) *TaskService {
	return &TaskService{repo: repo}
}

// Current — текущие задания пользователя: пул и свои взятые.
func (s *TaskService) Current(ctx context.Context, userID string) ([]model.Task, error) {
	return s.repo.Current(ctx, userID, TaskStaleAfter)
}

// Detail — задание с позициями и заходами по нему.
func (s *TaskService) Detail(ctx context.Context, id, userID string) (model.Task, []model.TaskSession, error) {
	if !isUUID(id) {
		return model.Task{}, nil, repository.ErrTaskNotFound
	}
	t, err := s.repo.ByID(ctx, id, userID)
	if err != nil {
		return model.Task{}, nil, err
	}
	sessions, err := s.repo.Sessions(ctx, id)
	if err != nil {
		return model.Task{}, nil, err
	}
	return t, sessions, nil
}

// Take — взять задание в работу.
func (s *TaskService) Take(ctx context.Context, id, userID string) error {
	if !isUUID(id) {
		return repository.ErrTaskNotFound
	}
	return s.repo.Take(ctx, id, userID, TaskStaleAfter)
}

// Release — отказаться от взятого задания: оно возвращается в пул.
func (s *TaskService) Release(ctx context.Context, id, userID string) error {
	if !isUUID(id) {
		return repository.ErrTaskNotFound
	}
	return s.repo.Release(ctx, id, userID)
}

// CompletedQuery — фильтр ленты в транспортном виде, как его шлёт ТСД.
//
// Даты — 'YYYY-MM-DD' по времени склада (МСК); `to` включается целиком. Курсор — время
// завершения (RFC3339) и id последней показанной записи.
type CompletedQuery struct {
	From, To          string
	ExecutorID        string
	Kind              string
	BeforeCompletedAt string
	BeforeID          string
	Limit             int
}

// warehouseZone — часовой пояс склада: «день» в фильтре — это день склада, а не UTC сервера.
var warehouseZone = func() *time.Location {
	loc, err := time.LoadLocation("Europe/Moscow")
	if err != nil {
		return time.FixedZone("MSK", 3*60*60)
	}
	return loc
}()

// Completed — страница ленты «Завершённые» по фильтру.
func (s *TaskService) Completed(ctx context.Context, q CompletedQuery) ([]model.CompletedTask, error) {
	f := model.CompletedTasksFilter{
		ExecutorID: strings.TrimSpace(q.ExecutorID),
		Kind:       strings.TrimSpace(q.Kind),
		BeforeID:   strings.TrimSpace(q.BeforeID),
		Limit:      q.Limit,
	}
	if f.Limit <= 0 {
		f.Limit = completedDefaultLimit
	}
	if f.Limit > completedMaxLimit {
		f.Limit = completedMaxLimit
	}
	if !isOptionalUUID(f.ExecutorID) || !isOptionalUUID(f.BeforeID) {
		return nil, ErrInvalidTaskFilter
	}
	if v := strings.TrimSpace(q.From); v != "" {
		d, err := time.ParseInLocation(time.DateOnly, v, warehouseZone)
		if err != nil {
			return nil, ErrInvalidTaskFilter
		}
		f.From = &d
	}
	if v := strings.TrimSpace(q.To); v != "" {
		d, err := time.ParseInLocation(time.DateOnly, v, warehouseZone)
		if err != nil {
			return nil, ErrInvalidTaskFilter
		}
		end := d.AddDate(0, 0, 1) // день «по» включается целиком
		f.To = &end
	}
	if v := strings.TrimSpace(q.BeforeCompletedAt); v != "" {
		t, err := time.Parse(time.RFC3339Nano, v)
		if err != nil || f.BeforeID == "" {
			return nil, ErrInvalidTaskFilter
		}
		f.BeforeCompletedAt = &t
	}
	return s.repo.Completed(ctx, f)
}

// Executors — варианты фильтра ленты по исполнителю.
func (s *TaskService) Executors(ctx context.Context) ([]model.TaskUser, error) {
	return s.repo.Executors(ctx)
}
