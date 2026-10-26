package service

import (
	"context"
	"slices"

	"craftwms/internal/model"
)

// stocktakeRepo — зависимость сервиса пересчёта.
type stocktakeRepo interface {
	Create(ctx context.Context, in model.StocktakeCreateInput) (model.StocktakeCreated, error)
	StartCount(ctx context.Context, stocktakeCellID, userID string) (model.StocktakeCellSnapshot, error)
}

// StocktakeService — пересчёт склада (P10): заведение по области и начало подсчёта ячейки.
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

// StartCount начинает подсчёт ячейки пересчёта тем, кто её держит: снимок «ожидалось» в момент
// скана ячейки на месте (P10-02).
func (s *StocktakeService) StartCount(ctx context.Context, stocktakeCellID, userID string) (model.StocktakeCellSnapshot, error) {
	if !isUUID(stocktakeCellID) || !isUUID(userID) {
		return model.StocktakeCellSnapshot{}, model.ErrInvalidStocktake
	}
	return s.repo.StartCount(ctx, stocktakeCellID, userID)
}
