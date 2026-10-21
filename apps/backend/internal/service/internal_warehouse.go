package service

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"unicode/utf8"

	"craftwms/internal/model"
)

// ErrInvalidInternalWarehouse — код или имя склада не годятся: код — латиница в верхнем
// регистре, цифры и «_» до 20 знаков, имя — непустое, до 100 символов.
var ErrInvalidInternalWarehouse = errors.New("invalid internal warehouse code or name")

// internalWarehouseCode — код склада для отчётов и импорта: коротко и без пробелов.
var internalWarehouseCode = regexp.MustCompile(`^[A-Z0-9_]{1,20}$`)

// internalWarehouseNameMax — предел имени в символах.
const internalWarehouseNameMax = 100

// internalWarehouseRepo — зависимость сервиса внутренних складов.
type internalWarehouseRepo interface {
	All(ctx context.Context) ([]model.InternalWarehouse, error)
	Create(ctx context.Context, code, name string) (model.InternalWarehouse, error)
	Update(ctx context.Context, id string, name *string, active *bool) (model.InternalWarehouse, error)
	Delete(ctx context.Context, id string) error
}

// InternalWarehouseService — справочник внутренних складов (P6-07-1, ADHOC-29): ТСД читает
// его, чтобы пометить товар браком и подписать помеченное; портал заводит, переименовывает,
// скрывает и удаляет склады, кроме склада по умолчанию.
type InternalWarehouseService struct {
	repo internalWarehouseRepo
}

// NewInternalWarehouseService создаёт сервис внутренних складов.
func NewInternalWarehouseService(repo internalWarehouseRepo) *InternalWarehouseService {
	return &InternalWarehouseService{repo: repo}
}

// List — все склады, и скрытые: склад по умолчанию первым.
func (s *InternalWarehouseService) List(ctx context.Context) ([]model.InternalWarehouse, error) {
	return s.repo.All(ctx)
}

// Create заводит склад. Код приводится к верхнему регистру: «defect» и «DEFECT» — один код.
func (s *InternalWarehouseService) Create(ctx context.Context, code, name string) (model.InternalWarehouse, error) {
	code = strings.ToUpper(strings.TrimSpace(code))
	name = strings.TrimSpace(name)
	if !internalWarehouseCode.MatchString(code) || !validWarehouseName(name) {
		return model.InternalWarehouse{}, ErrInvalidInternalWarehouse
	}
	return s.repo.Create(ctx, code, name)
}

// Update переименовывает склад и (или) скрывает его или возвращает в выбор. nil — не меняется.
func (s *InternalWarehouseService) Update(ctx context.Context, id string, name *string, active *bool) (model.InternalWarehouse, error) {
	if !isUUID(id) {
		return model.InternalWarehouse{}, ErrInvalidInternalWarehouse
	}
	if name != nil {
		trimmed := strings.TrimSpace(*name)
		if !validWarehouseName(trimmed) {
			return model.InternalWarehouse{}, ErrInvalidInternalWarehouse
		}
		name = &trimmed
	}
	return s.repo.Update(ctx, id, name, active)
}

// Delete удаляет склад без остатка и истории.
func (s *InternalWarehouseService) Delete(ctx context.Context, id string) error {
	if !isUUID(id) {
		return ErrInvalidInternalWarehouse
	}
	return s.repo.Delete(ctx, id)
}

func validWarehouseName(name string) bool {
	return name != "" && utf8.RuneCountInString(name) <= internalWarehouseNameMax
}
