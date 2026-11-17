package service

import (
	"context"
	"errors"
	"strings"

	"github.com/google/uuid"

	"craftwms/internal/model"
)

// Ошибки грузовой единицы (P4-03).
var (
	// ErrInvalidLoadUnitID - идентификатор ГЕ не UUID.
	ErrInvalidLoadUnitID = errors.New("load unit id must be a UUID")
	// ErrInvalidLoadUnitKind - вид ГЕ не «короб» и не «паллета».
	ErrInvalidLoadUnitKind = errors.New("load unit kind must be box or pallet")
)

// loadUnitRepo - зависимость сервиса от хранилища грузовых единиц.
type loadUnitRepo interface {
	Create(ctx context.Context, id, kind string) error
	ByID(ctx context.Context, id string) (model.LoadUnit, error)
}

// LoadUnitService - грузовая единица: заведение короба, собранного на приёмке, и его чтение.
type LoadUnitService struct {
	repo loadUnitRepo
}

// NewLoadUnitService собирает сервис грузовых единиц.
func NewLoadUnitService(repo loadUnitRepo) *LoadUnitService {
	return &LoadUnitService{repo: repo}
}

// Create заводит ГЕ с идентификатором, выданным устройством (UUID из QR ярлыка, P4-04).
//
// UUID проверяем здесь, а не полагаемся на приведение типа в БД: иначе кладовщик получил бы
// сбой запроса вместо внятного «неверный код ГЕ», а сканирование чужого QR - рабочая ситуация,
// пока распознавание ярлыка держится на символике (это меняется в P4-04).
func (s *LoadUnitService) Create(ctx context.Context, id, kind string) error {
	id = strings.TrimSpace(id)
	if _, err := uuid.Parse(id); err != nil {
		return ErrInvalidLoadUnitID
	}
	kind = strings.TrimSpace(kind)
	if kind == "" {
		kind = model.LoadUnitBox // приёмка собирает короба; паллета - явный выбор
	}
	if kind != model.LoadUnitBox && kind != model.LoadUnitPallet {
		return ErrInvalidLoadUnitKind
	}
	return s.repo.Create(ctx, id, kind)
}

// Get возвращает шапку ГЕ - чтобы устройство показало кладовщику, что за короб он отсканировал.
func (s *LoadUnitService) Get(ctx context.Context, id string) (model.LoadUnit, error) {
	id = strings.TrimSpace(id)
	if _, err := uuid.Parse(id); err != nil {
		return model.LoadUnit{}, ErrInvalidLoadUnitID
	}
	return s.repo.ByID(ctx, id)
}
