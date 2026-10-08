package service

import (
	"context"
	"errors"
	"regexp"
	"strings"

	"github.com/google/uuid"

	"craftwms/internal/model"
)

// Ошибки просмотра содержимого.
var (
	// ErrInvalidCellID — идентификатор ячейки не UUID.
	ErrInvalidCellID = errors.New("cell id must be a UUID")
	// ErrInvalidShortCode — короткий код не из 1…8 шестнадцатеричных знаков.
	ErrInvalidShortCode = errors.New("short code must be 1 to 8 hex digits")
)

// shortCodeSearchLimit — сколько коробов отдаёт поиск по короткому коду. По одному-двум знакам
// совпадает пол-склада; кладовщику нужен его короб, а не выгрузка, — он допишет код.
const shortCodeSearchLimit = 50

// shortCodePattern — короткий код после приведения: хвост UUID, шестнадцатеричные знаки.
var shortCodePattern = regexp.MustCompile(`^[0-9A-F]{1,8}$`)

// contentsRepo — зависимость сервиса от хранилища: только чтение содержимого.
type contentsRepo interface {
	Snapshot(ctx context.Context) (model.ContentsSnapshot, error)
	CellContents(ctx context.Context, cellID string) (model.CellContents, error)
	LoadUnitCard(ctx context.Context, id string) (model.LoadUnitCard, error)
	SearchLoadUnits(ctx context.Context, code string, limit int) ([]model.LoadUnitCard, error)
	LoadUnitHistory(ctx context.Context, id string) (model.LoadUnitHistory, error)
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

// SearchLoadUnits — короба по короткому коду с ярлыка (P5-05-1), живые и нет.
//
// Код приводится так же, как на ТСД (`LoadUnitLabel.normalizeShortCode`): без пробелов
// и дефисов, заглавными. На ярлыке код разбит пробелом, и человек набирает его так, как видит.
func (s *ContentsService) SearchLoadUnits(ctx context.Context, raw string) ([]model.LoadUnitCard, error) {
	code := strings.ToUpper(strings.NewReplacer(" ", "", "-", "", "\t", "").Replace(raw))
	if !shortCodePattern.MatchString(code) {
		return nil, ErrInvalidShortCode
	}
	return s.repo.SearchLoadUnits(ctx, code, shortCodeSearchLimit)
}

// LoadUnitHistory — история короба: приёмка и переносы.
func (s *ContentsService) LoadUnitHistory(ctx context.Context, id string) (model.LoadUnitHistory, error) {
	id = strings.TrimSpace(id)
	if _, err := uuid.Parse(id); err != nil {
		return model.LoadUnitHistory{}, ErrInvalidLoadUnitID
	}
	return s.repo.LoadUnitHistory(ctx, id)
}
