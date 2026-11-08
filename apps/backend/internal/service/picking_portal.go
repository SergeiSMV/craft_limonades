package service

import (
	"context"
	"time"

	"craftwms/internal/model"
	"craftwms/internal/report"
)

// pickingPortalRepo — узкий интерфейс хранилища сборки для раздела портала (P8-03).
type pickingPortalRepo interface {
	PortalOrders(ctx context.Context, warehouseID string, date time.Time) ([]model.PickingPortalOrder, error)
	PortalOrder(ctx context.Context, orderID string) (model.PickingPortalDetail, error)
	PortalDetails(ctx context.Context, warehouseID string, date time.Time) ([]model.PickingPortalDetail, error)
	ForceReleaseOrder(ctx context.Context, orderID string) error
}

// PickingPortalService — раздел портала «Сборка-отгрузка» (P8-03): заказы на дату накладной,
// окно деталей план/факт, выгрузка Excel и снятие заказа с исполнителя старшим смены.
//
// Склад — по коду (склад пилота), как у загрузки реестра; неизвестный код — ErrNotFound
// хранилища. Идентификатор заказа из пути проверяется здесь: не UUID — «не найдено».
type PickingPortalService struct {
	repo       pickingPortalRepo
	warehouses pickingWarehouses
}

// NewPickingPortalService собирает сервис раздела портала.
func NewPickingPortalService(repo pickingPortalRepo, warehouses pickingWarehouses) *PickingPortalService {
	return &PickingPortalService{repo: repo, warehouses: warehouses}
}

// Orders — заказы склада на дату накладной, удалённые в 1С — с пометкой, в конце.
func (s *PickingPortalService) Orders(ctx context.Context, warehouseCode string, date time.Time) ([]model.PickingPortalOrder, error) {
	id, err := s.warehouses.IDByCode(ctx, warehouseCode)
	if err != nil {
		return nil, err
	}
	return s.repo.PortalOrders(ctx, id, date)
}

// Order — заказ для окна деталей: строки план/факт с марками, короба, правки реестра.
func (s *PickingPortalService) Order(ctx context.Context, orderID string) (model.PickingPortalDetail, error) {
	if !isUUID(orderID) {
		return model.PickingPortalDetail{}, model.ErrPickingOrderNotFound
	}
	return s.repo.PortalOrder(ctx, orderID)
}

// Release — снять заказ с исполнителя: снова «новый», собранное остаётся в коробах.
func (s *PickingPortalService) Release(ctx context.Context, orderID string) error {
	if !isUUID(orderID) {
		return model.ErrPickingOrderNotFound
	}
	return s.repo.ForceReleaseOrder(ctx, orderID)
}

// ExportXLSX — выгрузка всех заказов даты на момент нажатия: файл и его имя.
func (s *PickingPortalService) ExportXLSX(ctx context.Context, warehouseCode string, date time.Time) ([]byte, string, error) {
	id, err := s.warehouses.IDByCode(ctx, warehouseCode)
	if err != nil {
		return nil, "", err
	}
	orders, err := s.repo.PortalDetails(ctx, id, date)
	if err != nil {
		return nil, "", err
	}
	data, err := report.BuildPickingXLSX(date, orders)
	if err != nil {
		return nil, "", err
	}
	return data, report.PickingXLSXName(warehouseCode, date), nil
}
