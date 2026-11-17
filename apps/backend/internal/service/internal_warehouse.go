package service

import (
	"context"
	"regexp"
	"strings"
	"unicode/utf8"

	"craftwms/internal/model"
)

// internalWarehouseCode - код склада для отчётов и импорта: коротко и без пробелов.
var internalWarehouseCode = regexp.MustCompile(`^[A-Z0-9_]{1,20}$`)

// internalWarehouseNameMax - предел имени в символах.
const internalWarehouseNameMax = 100

// internalWarehouseRepo - зависимость сервиса внутренних складов.
type internalWarehouseRepo interface {
	All(ctx context.Context) ([]model.InternalWarehouse, error)
	Create(ctx context.Context, code, name string) (model.InternalWarehouse, error)
	Update(ctx context.Context, id string, name *string, active, allowPicking *bool) (model.InternalWarehouse, error)
	Delete(ctx context.Context, id string) error
}

// InternalWarehouseService - справочник внутренних складов (P6-07-1, ADHOC-29): ТСД читает
// его, чтобы пометить товар браком и подписать помеченное; портал заводит, переименовывает,
// скрывает и удаляет склады, кроме склада по умолчанию.
type InternalWarehouseService struct {
	repo internalWarehouseRepo
}

// NewInternalWarehouseService создаёт сервис внутренних складов.
func NewInternalWarehouseService(repo internalWarehouseRepo) *InternalWarehouseService {
	return &InternalWarehouseService{repo: repo}
}

// List - все склады, и скрытые: склад по умолчанию первым.
func (s *InternalWarehouseService) List(ctx context.Context) ([]model.InternalWarehouse, error) {
	return s.repo.All(ctx)
}

// Create заводит склад. Код приводится к верхнему регистру: «defect» и «DEFECT» - один код.
func (s *InternalWarehouseService) Create(ctx context.Context, code, name string) (model.InternalWarehouse, error) {
	code = strings.ToUpper(strings.TrimSpace(code))
	name = strings.TrimSpace(name)
	if !internalWarehouseCode.MatchString(code) || !validWarehouseName(name) {
		return model.InternalWarehouse{}, model.ErrInvalidInternalWarehouse
	}
	return s.repo.Create(ctx, code, name)
}

// Update переименовывает склад, скрывает его или возвращает в выбор, разрешает или запрещает
// сборку из него. nil - не меняется.
func (s *InternalWarehouseService) Update(ctx context.Context, id string, name *string, active, allowPicking *bool) (model.InternalWarehouse, error) {
	if !isUUID(id) {
		return model.InternalWarehouse{}, model.ErrInvalidInternalWarehouse
	}
	if name != nil {
		trimmed := strings.TrimSpace(*name)
		if !validWarehouseName(trimmed) {
			return model.InternalWarehouse{}, model.ErrInvalidInternalWarehouse
		}
		name = &trimmed
	}
	return s.repo.Update(ctx, id, name, active, allowPicking)
}

// Delete удаляет склад без остатка и истории.
func (s *InternalWarehouseService) Delete(ctx context.Context, id string) error {
	if !isUUID(id) {
		return model.ErrInvalidInternalWarehouse
	}
	return s.repo.Delete(ctx, id)
}

func validWarehouseName(name string) bool {
	return name != "" && utf8.RuneCountInString(name) <= internalWarehouseNameMax
}
