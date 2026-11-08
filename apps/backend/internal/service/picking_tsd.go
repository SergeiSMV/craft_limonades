package service

import (
	"context"

	"craftwms/internal/model"
)

// PickingStaleAfter — заказ без движения столько времени считается зависшим: его видят свободным
// и может взять другой кладовщик; собранное остаётся в коробах (docs/picking.md, «Статусы»).
const PickingStaleAfter = TaskStaleAfter

// Цикл сборки на ТСД (P9-04): список, взять, отказаться, короб отгрузки, «не хватает». Пик и
// списание «в сборку» — P9-05. Идентификаторы из пути проверяются здесь: не UUID — «не найдено»,
// а не ошибка базы.

// Orders — список «СБОРКА»: все несобранные заказы любой даты.
func (s *PickingTaskService) Orders(ctx context.Context, userID string) ([]model.PickingOrderListItem, error) {
	return s.repo.OpenOrders(ctx, userID, PickingStaleAfter)
}

// Take — взять заказ в работу.
func (s *PickingTaskService) Take(ctx context.Context, orderID, userID string) error {
	if !isUUID(orderID) {
		return model.ErrPickingOrderNotFound
	}
	return s.repo.TakeOrder(ctx, orderID, userID, PickingStaleAfter)
}

// Release — отказаться от заказа: он снова «новый».
func (s *PickingTaskService) Release(ctx context.Context, orderID, userID string) error {
	if !isUUID(orderID) {
		return model.ErrPickingOrderNotFound
	}
	return s.repo.ReleaseOrder(ctx, orderID, userID)
}

// AddBox — завести короб отгрузки с ярлыком loadUnitID (UUID выдаёт ТСД, как у коробов приёмки);
// возвращает номер короба в заказе.
func (s *PickingTaskService) AddBox(ctx context.Context, orderID, userID, loadUnitID string) (int, error) {
	if !isUUID(orderID) {
		return 0, model.ErrPickingOrderNotFound
	}
	if !isUUID(loadUnitID) {
		return 0, model.ErrPickingBoxID
	}
	return s.repo.AddBox(ctx, orderID, userID, loadUnitID)
}

// MarkShortage — отметка «не хватает» по строке; при отметке заводится пересчёт позиции.
func (s *PickingTaskService) MarkShortage(ctx context.Context, orderID, lineID, userID string, shortage bool) (model.PickingShortageResult, error) {
	if !isUUID(orderID) {
		return model.PickingShortageResult{}, model.ErrPickingOrderNotFound
	}
	if !isUUID(lineID) {
		return model.PickingShortageResult{}, model.ErrPickingLineNotFound
	}
	return s.repo.MarkShortage(ctx, orderID, lineID, userID, shortage)
}

// Complete — «Завершить сборку» (P9-07): остаток из ячеек в короба отгрузки, короба — в
// `ОТГРУЗКУ`, заказ — «собран». Возвращает заказ с коробами «N из M» для ярлыков.
func (s *PickingTaskService) Complete(ctx context.Context, orderID, userID string) (model.PickingShipment, error) {
	if !isUUID(orderID) {
		return model.PickingShipment{}, model.ErrPickingOrderNotFound
	}
	return s.repo.CompleteOrder(ctx, orderID, userID)
}

// Shipment — собранный заказ с коробами для ярлыков и отгрузки.
func (s *PickingTaskService) Shipment(ctx context.Context, orderID string) (model.PickingShipment, error) {
	if !isUUID(orderID) {
		return model.PickingShipment{}, model.ErrPickingOrderNotFound
	}
	return s.repo.Shipment(ctx, orderID)
}

// PrintLabels — отметить печать ярлыков коробов; уже печатавшийся — только с правом повтора.
func (s *PickingTaskService) PrintLabels(ctx context.Context, orderID string, boxIDs []string, canReprint bool) (model.PickingShipment, error) {
	if !isUUID(orderID) {
		return model.PickingShipment{}, model.ErrPickingOrderNotFound
	}
	if !allUUID(boxIDs) {
		return model.PickingShipment{}, model.ErrPickingShipBoxes
	}
	return s.repo.PrintLabels(ctx, orderID, boxIDs, canReprint)
}

// Ship — «Отгрузить»: отсканированы ярлыки всех коробов заказа.
func (s *PickingTaskService) Ship(ctx context.Context, orderID, userID string, boxIDs []string) (model.PickingShipment, error) {
	if !isUUID(orderID) {
		return model.PickingShipment{}, model.ErrPickingOrderNotFound
	}
	if !allUUID(boxIDs) {
		return model.PickingShipment{}, model.ErrPickingShipBoxes
	}
	return s.repo.ShipOrder(ctx, orderID, userID, boxIDs)
}

// allUUID — все идентификаторы в формате UUID: иначе короб точно не из заказа.
func allUUID(ids []string) bool {
	for _, id := range ids {
		if !isUUID(id) {
			return false
		}
	}
	return true
}
