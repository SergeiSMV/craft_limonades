package service

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/picking"
	"craftwms/internal/repository"
)

// pickingTaskRepo — узкий интерфейс хранилища сборки для подбора.
type pickingTaskRepo interface {
	TaskOrder(ctx context.Context, orderID string) (model.PickingTaskOrder, error)
	Sources(ctx context.Context, warehouseID string, goodIDs []string) ([]picking.Source, error)
	OpenOrders(ctx context.Context, userID string, staleAfter time.Duration) ([]model.PickingOrderListItem, error)
	TakeOrder(ctx context.Context, orderID, userID string, staleAfter time.Duration) error
	ReleaseOrder(ctx context.Context, orderID, userID string) error
	AddBox(ctx context.Context, orderID, userID, loadUnitID string) (int, error)
	MarkShortage(ctx context.Context, orderID, lineID, userID string, shortage bool) (model.PickingShortageResult, error)
}

// PickingTaskService — задание на сборку (P9-03): заказ с планом и подбором источников.
//
// Задание сборки — сам заказ (P9-02): отдельной строки в заданиях склада у него нет. Сервис
// проверяет, что заказ можно собирать, и строит подбор по текущему остатку — партия и ячейка
// реестра, иначе FEFO и ячейка WMS (пакет picking). Резерва нет: подбор — подсказка на момент
// запроса, остаток проверяет пик (P9-05).
type PickingTaskService struct {
	repo pickingTaskRepo
}

// NewPickingTaskService собирает сервис задания на сборку.
func NewPickingTaskService(repo pickingTaskRepo) *PickingTaskService {
	return &PickingTaskService{repo: repo}
}

// PickingTask — заказ с подбором по строкам. Lines — в порядке плана; у убранной реестром
// строки подбора нет (Suggestion — nil).
type PickingTask struct {
	Order model.PickingTaskOrder
	Lines []PickingTaskLine
}

// PickingTaskLine — строка плана и её подбор.
type PickingTaskLine struct {
	Line       model.PickingTaskLine
	Suggestion *picking.Suggestion
}

// Task — заказ, готовый к сборке, с подбором источников.
//
// Отказ: заказа нет, он удалён в 1С, в нём есть нераспознанные позиции (сборка не начинается,
// пока не обновят номенклатуру и не загрузят реестр повторно) или он уже собран/отгружен —
// дособор после правки реестра возвращает заказ в «в работе» сам (P8-02).
func (s *PickingTaskService) Task(ctx context.Context, orderID string) (PickingTask, error) {
	if !isUUID(orderID) {
		return PickingTask{}, model.ErrPickingOrderNotFound
	}
	o, err := s.repo.TaskOrder(ctx, orderID)
	if errors.Is(err, repository.ErrNotFound) {
		return PickingTask{}, model.ErrPickingOrderNotFound
	}
	if err != nil {
		return PickingTask{}, err
	}
	if err := pickable(o); err != nil {
		return PickingTask{}, err
	}

	var goodIDs []string
	seen := map[string]bool{}
	for _, l := range o.Lines {
		if l.GoodID != nil && !l.Removed && !seen[*l.GoodID] {
			seen[*l.GoodID] = true
			goodIDs = append(goodIDs, *l.GoodID)
		}
	}
	sources, err := s.repo.Sources(ctx, o.WarehouseID, goodIDs)
	if err != nil {
		return PickingTask{}, fmt.Errorf("подбор заказа СБ-%d: %w", o.Number, err)
	}
	return buildPickingTask(o, sources), nil
}

// pickable — можно ли собирать заказ.
func pickable(o model.PickingTaskOrder) error {
	switch {
	case o.Deleted:
		return model.ErrPickingOrderDeleted
	case o.HasUnknown:
		return model.ErrPickingOrderUnknown
	case o.Status != model.PickingStatusNew && o.Status != model.PickingStatusInProgress:
		return model.ErrPickingOrderClosed
	}
	return nil
}

// buildPickingTask подбирает источники живым строкам заказа и раскладывает подбор по строкам.
func buildPickingTask(o model.PickingTaskOrder, sources []picking.Source) PickingTask {
	var lines []picking.Line
	var at []int // строка подбора → индекс строки заказа
	for i, l := range o.Lines {
		if l.Removed || l.GoodID == nil {
			continue
		}
		lines = append(lines, picking.Line{
			ID: l.ID, GoodID: *l.GoodID, BatchDate: l.BatchDate, CellID: l.CellID,
			RegistryCell: l.RegistryCell, PlanQty: decimal.NewFromInt(int64(l.PlanQty)), Taken: l.Taken,
		})
		at = append(at, i)
	}
	suggestions := picking.SuggestOrder(lines, sources)

	task := PickingTask{Order: o, Lines: make([]PickingTaskLine, len(o.Lines))}
	for i, l := range o.Lines {
		task.Lines[i].Line = l
	}
	for k, i := range at {
		sg := suggestions[k]
		task.Lines[i].Suggestion = &sg
	}
	return task
}
