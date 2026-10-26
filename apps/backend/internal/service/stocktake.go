package service

import (
	"context"
	"slices"
	"time"

	"craftwms/internal/model"
)

// StocktakeCellStaleAfter — через сколько взятая и не начатая ячейка пересчёта снова видна
// всем: как у заданий (решение 2026-10-07), работник мог уйти со смены, не отказавшись.
const StocktakeCellStaleAfter = 8 * time.Hour

// stocktakeRepo — зависимость сервиса пересчёта.
type stocktakeRepo interface {
	Create(ctx context.Context, in model.StocktakeCreateInput) (model.StocktakeCreated, error)
	Get(ctx context.Context, id, userID string, staleAfter time.Duration) (model.Stocktake, error)
	Cells(ctx context.Context, stocktakeID, userID string, staleAfter time.Duration) ([]model.StocktakeCell, error)
	Take(ctx context.Context, id, userID string, staleAfter time.Duration) error
	Release(ctx context.Context, id, userID string) error
	StartCount(ctx context.Context, stocktakeCellID, userID string) (model.StocktakeCellView, error)
	CellView(ctx context.Context, id, userID string) (model.StocktakeCellView, error)
	Close(ctx context.Context, id, userID string, force bool) (int, error)
	List(ctx context.Context, status string) ([]model.StocktakeListItem, error)
	CountingInCell(ctx context.Context, cellID string) (*model.CellUnderCount, error)
}

// StocktakeService — пересчёт склада (P10): заведение по области, ячейки для работника,
// взятие и начало подсчёта, закрытие. Подсчёт ячейки — операция очереди (OperationsService).
type StocktakeService struct {
	repo stocktakeRepo
}

// NewStocktakeService создаёт сервис пересчёта.
func NewStocktakeService(repo stocktakeRepo) *StocktakeService {
	return &StocktakeService{repo: repo}
}

// Create заводит пересчёт по области (P10-02).
//
// Проверяет форму: вид области известен; у «всего склада» объектов нет, у остальных — хотя бы
// один; все идентификаторы — UUID. Повторы объектов схлопываются: старший смены мог выбрать
// одну группу дважды, и это не ошибка. Существование объектов и склад ячеек проверяет хранилище.
func (s *StocktakeService) Create(ctx context.Context, in model.StocktakeCreateInput) (model.StocktakeCreated, error) {
	if !slices.Contains(model.StocktakeScopeKinds, in.ScopeKind) ||
		!isUUID(in.WarehouseID) || !isUUID(in.CreatedBy) {
		return model.StocktakeCreated{}, model.ErrInvalidStocktake
	}
	objects := make([]string, 0, len(in.ObjectIDs))
	for _, id := range in.ObjectIDs {
		if !isUUID(id) {
			return model.StocktakeCreated{}, model.ErrInvalidStocktake
		}
		if !slices.Contains(objects, id) {
			objects = append(objects, id)
		}
	}
	if (in.ScopeKind == model.StocktakeScopeAll) != (len(objects) == 0) {
		return model.StocktakeCreated{}, model.ErrInvalidStocktake
	}
	in.ObjectIDs = objects
	return s.repo.Create(ctx, in)
}

// Get — пересчёт с ходом выполнения: шапка и все ячейки (P10-03).
func (s *StocktakeService) Get(ctx context.Context, id, userID string) (model.Stocktake, error) {
	if !isUUID(id) {
		return model.Stocktake{}, model.ErrStocktakeNotFound
	}
	return s.repo.Get(ctx, id, userID, StocktakeCellStaleAfter)
}

// Cells — ячейки пересчёта, которые работник может считать: свободные и свои (P10-03).
func (s *StocktakeService) Cells(ctx context.Context, stocktakeID, userID string) ([]model.StocktakeCell, error) {
	if !isUUID(stocktakeID) {
		return nil, model.ErrStocktakeNotFound
	}
	return s.repo.Cells(ctx, stocktakeID, userID, StocktakeCellStaleAfter)
}

// Take отдаёт ячейку пересчёта работнику (P10-03).
func (s *StocktakeService) Take(ctx context.Context, id, userID string) error {
	if !isUUID(id) {
		return model.ErrStocktakeCellNotFound
	}
	return s.repo.Take(ctx, id, userID, StocktakeCellStaleAfter)
}

// Release возвращает свою ячейку пересчёта в общий список (P10-03).
func (s *StocktakeService) Release(ctx context.Context, id, userID string) error {
	if !isUUID(id) {
		return model.ErrStocktakeCellNotFound
	}
	return s.repo.Release(ctx, id, userID)
}

// StartCount начинает подсчёт ячейки пересчёта тем, кто её держит: снимок «ожидалось» в момент
// скана ячейки на месте (P10-02). Возвращает позиции снимка без количеств (P10-03).
func (s *StocktakeService) StartCount(ctx context.Context, stocktakeCellID, userID string) (model.StocktakeCellView, error) {
	if !isUUID(stocktakeCellID) {
		return model.StocktakeCellView{}, model.ErrStocktakeCellNotFound
	}
	return s.repo.StartCount(ctx, stocktakeCellID, userID)
}

// CellView — своя ячейка пересчёта с позициями снимка (P10-03).
func (s *StocktakeService) CellView(ctx context.Context, id, userID string) (model.StocktakeCellView, error) {
	if !isUUID(id) {
		return model.StocktakeCellView{}, model.ErrStocktakeCellNotFound
	}
	return s.repo.CellView(ctx, id, userID)
}

// Close закрывает пересчёт (P10-03); force — закрыть досрочно, с неподсчитанными ячейками.
// Возвращает, сколько ячеек осталось неподсчитанными.
func (s *StocktakeService) Close(ctx context.Context, id, userID string, force bool) (int, error) {
	if !isUUID(id) {
		return 0, model.ErrStocktakeNotFound
	}
	return s.repo.Close(ctx, id, userID, force)
}

// List — пересчёты для портала (P10-05): `open`, `closed` или пусто — все.
func (s *StocktakeService) List(ctx context.Context, status string) ([]model.StocktakeListItem, error) {
	if status != "" && status != "open" && status != "closed" {
		return nil, model.ErrInvalidStocktake
	}
	return s.repo.List(ctx, status)
}

// CountingInCell — подсчёт, идущий в ячейке склада (ADHOC-48); nil — не идёт. Неверный id —
// тоже nil: ячейки с таким id нет, и подсчёта в ней нет.
func (s *StocktakeService) CountingInCell(ctx context.Context, cellID string) (*model.CellUnderCount, error) {
	if !isUUID(cellID) {
		return nil, nil
	}
	return s.repo.CountingInCell(ctx, cellID)
}
