package service

import (
	"context"

	"craftwms/internal/model"
)

// internalWarehouseRepo — зависимость сервиса внутренних складов.
type internalWarehouseRepo interface {
	Active(ctx context.Context) ([]model.InternalWarehouse, error)
}

// InternalWarehouseService — справочник внутренних складов для ТСД (P6-07-1): куда пометить
// товар — «Брак», «Изолятор» и т. п. Заводит и скрывает склады портал (отдельная задача).
type InternalWarehouseService struct {
	repo internalWarehouseRepo
}

// NewInternalWarehouseService создаёт сервис внутренних складов.
func NewInternalWarehouseService(repo internalWarehouseRepo) *InternalWarehouseService {
	return &InternalWarehouseService{repo: repo}
}

// Active — действующие внутренние склады, склад по умолчанию первым.
func (s *InternalWarehouseService) Active(ctx context.Context) ([]model.InternalWarehouse, error) {
	return s.repo.Active(ctx)
}
