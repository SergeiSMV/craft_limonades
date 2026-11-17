package service

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// pickingPickPayload - тело операции picking_pick, как его собирает ТСД (P9-05).
//
// pick_id выдаёт устройство - по нему пик возвращают (picking_unpick). Источник - ровно один:
// ячейка (`source_cell_id`, россыпь; склад - `internal_warehouse_id`, пусто - «Основной») или
// короб хранения (`source_load_unit_id`: его ячейку и склад знает сервер). Партия - датой
// производства, как в движении; марки - КИ маркируемого товара, по одной на единицу.
type pickingPickPayload struct {
	PickID              string          `json:"pick_id"`
	OrderID             string          `json:"order_id"`
	LineID              string          `json:"line_id"`
	BoxID               string          `json:"box_id"`
	SourceCellID        string          `json:"source_cell_id"`
	SourceLoadUnitID    string          `json:"source_load_unit_id"`
	InternalWarehouseID string          `json:"internal_warehouse_id"`
	ProductionDate      string          `json:"production_date"`
	Qty                 decimal.Decimal `json:"qty"`
	Marks               []string        `json:"marks"`
}

// pickingPick разбирает и проверяет пик из очереди ТСД. Автор - из токена; всё, что
// проверяется без базы, - здесь.
func (s *OperationsService) pickingPick(ctx context.Context, userID, id string, raw json.RawMessage) (repository.Applied, error) {
	var p pickingPickPayload
	if err := json.Unmarshal(raw, &p); err != nil {
		return repository.Applied{}, model.ErrInvalidPayload
	}
	in := repository.PickingPickInput{
		PickID:              strings.TrimSpace(p.PickID),
		OrderID:             strings.TrimSpace(p.OrderID),
		LineID:              strings.TrimSpace(p.LineID),
		BoxID:               strings.TrimSpace(p.BoxID),
		SourceCellID:        strings.TrimSpace(p.SourceCellID),
		SourceLoadUnitID:    strings.TrimSpace(p.SourceLoadUnitID),
		InternalWarehouseID: strings.TrimSpace(p.InternalWarehouseID),
		Qty:                 p.Qty,
		PickedBy:            userID,
	}
	for _, v := range []string{in.PickID, in.OrderID, in.LineID, in.BoxID} {
		if !isUUID(v) {
			return repository.Applied{}, model.ErrInvalidPayload
		}
	}
	if (in.SourceCellID == "") == (in.SourceLoadUnitID == "") {
		return repository.Applied{}, model.ErrInvalidPayload
	}
	for _, v := range []string{in.SourceCellID, in.SourceLoadUnitID, in.InternalWarehouseID} {
		if v != "" && !isUUID(v) {
			return repository.Applied{}, model.ErrInvalidPayload
		}
	}
	if !in.Qty.IsPositive() {
		return repository.Applied{}, model.ErrInvalidQuantity
	}
	iso, err := parseEntryDate(p.ProductionDate)
	if err != nil {
		return repository.Applied{}, err
	}
	in.ProductionDate = iso
	if in.Marks, err = lineMarks(p.Marks); err != nil {
		return repository.Applied{}, err
	}
	return s.repo.PickingPick(ctx, id, in)
}

// pickingUnpick разбирает возврат пика: {"pick_id": …}.
func (s *OperationsService) pickingUnpick(ctx context.Context, id string, raw json.RawMessage) (repository.Applied, error) {
	var p struct {
		PickID string `json:"pick_id"`
	}
	if err := json.Unmarshal(raw, &p); err != nil || !isUUID(strings.TrimSpace(p.PickID)) {
		return repository.Applied{}, model.ErrInvalidPayload
	}
	return s.repo.PickingUnpick(ctx, id, strings.TrimSpace(p.PickID))
}

// pickingReturn разбирает возврат на место (P9-07-1):
// {"return_id", "pick_id", "cell_id", "qty", "marks"}. return_id выдаёт устройство.
func (s *OperationsService) pickingReturn(ctx context.Context, userID, id string, raw json.RawMessage) (repository.Applied, error) {
	var p struct {
		ReturnID string          `json:"return_id"`
		PickID   string          `json:"pick_id"`
		CellID   string          `json:"cell_id"`
		Qty      decimal.Decimal `json:"qty"`
		Marks    []string        `json:"marks"`
	}
	if err := json.Unmarshal(raw, &p); err != nil {
		return repository.Applied{}, model.ErrInvalidPayload
	}
	in := repository.PickingReturnInput{
		ReturnID: strings.TrimSpace(p.ReturnID),
		PickID:   strings.TrimSpace(p.PickID),
		CellID:   strings.TrimSpace(p.CellID),
		Qty:      p.Qty,
		UserID:   userID,
	}
	for _, v := range []string{in.ReturnID, in.PickID, in.CellID} {
		if !isUUID(v) {
			return repository.Applied{}, model.ErrInvalidPayload
		}
	}
	if !in.Qty.IsPositive() {
		return repository.Applied{}, model.ErrInvalidQuantity
	}
	var err error
	if in.Marks, err = lineMarks(p.Marks); err != nil {
		return repository.Applied{}, err
	}
	return s.repo.PickingReturn(ctx, id, in)
}

// pickingRejections - отказы сборки по существу (P9-03…P9-05): повтор их не исправит.
var pickingRejections = []error{
	model.ErrPickingOrderNotFound, model.ErrPickingOrderDeleted, model.ErrPickingOrderClosed,
	model.ErrPickingLineNotFound, model.ErrPickingOverPlan, model.ErrPickingSourceDenied,
	model.ErrPickingBoxNotInOrder, model.ErrPickingSourceIsBox, model.ErrPickingPickExists,
	model.ErrPickingPickNotFound, model.ErrPickingPickMoved, model.ErrPickingStockShort,
	model.ErrPickingLoadUnitBusy, model.ErrPickingMarkInPicking, model.ErrShippingCell,
	// Возврат на места (P9-07-1).
	model.ErrPickingReturnOverLeft, model.ErrPickingReturnCell, model.ErrPickingReturnMarks,
	model.ErrPickingReturnNotMoved, model.ErrPickingReturnExists,
}
