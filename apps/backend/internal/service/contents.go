package service

import (
	"context"
	"errors"
	"strings"

	"github.com/google/uuid"

	"craftwms/internal/model"
)

// ErrInvalidCellID — идентификатор ячейки не UUID.
var ErrInvalidCellID = errors.New("cell id must be a UUID")

// contentsRepo — зависимость сервиса от хранилища: только чтение содержимого.
type contentsRepo interface {
	Snapshot(ctx context.Context) (model.ContentsSnapshot, error)
	CellContents(ctx context.Context, cellID string) (model.CellContents, error)
	LoadUnitCard(ctx context.Context, id string) (model.LoadUnitCard, error)
}

// ContentsService — просмотр содержимого ячеек и коробов на ТСД (P5-05).
//
// Что: карточка короба, содержимое ячейки и снимок для кэша терминала.
// Зачем: кладовщик сканирует ячейку или короб и видит, что внутри, — со связью из этих
// ручек, без связи из снимка, загруженного заранее.
type ContentsService struct {
	repo contentsRepo
}

// NewContentsService собирает сервис просмотра содержимого.
func NewContentsService(repo contentsRepo) *ContentsService {
	return &ContentsService{repo: repo}
}

// Snapshot — все живые короба и россыпь одним согласованным снимком.
func (s *ContentsService) Snapshot(ctx context.Context) (model.ContentsSnapshot, error) {
	return s.repo.Snapshot(ctx)
}

// CellContents — живые короба и россыпь ячейки.
//
// UUID проверяется здесь: иначе кривой идентификатор дошёл бы до БД и вернулся сбоем запроса
// вместо внятного «неверная ячейка».
func (s *ContentsService) CellContents(ctx context.Context, cellID string) (model.CellContents, error) {
	cellID = strings.TrimSpace(cellID)
	if _, err := uuid.Parse(cellID); err != nil {
		return model.CellContents{}, ErrInvalidCellID
	}
	return s.repo.CellContents(ctx, cellID)
}

// LoadUnitCard — карточка короба, в том числе неживого (не размещён или пуст).
func (s *ContentsService) LoadUnitCard(ctx context.Context, id string) (model.LoadUnitCard, error) {
	id = strings.TrimSpace(id)
	if _, err := uuid.Parse(id); err != nil {
		return model.LoadUnitCard{}, ErrInvalidLoadUnitID
	}
	return s.repo.LoadUnitCard(ctx, id)
}
