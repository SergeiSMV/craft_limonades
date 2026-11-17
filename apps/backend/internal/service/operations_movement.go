package service

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// movementSubmitPayload - тело операции movement_submit, как его собирает устройство (P6-03).
//
// Строка - ГЕ целиком (`load_unit_id` + `to_cell_id`) ЛИБО товар (`good_id` +
// `production_date` + `qty`) с одним источником и одним приёмником: источник - ячейка
// (`from_cell_id`, россыпь) или короб (`from_load_unit_id`), приёмник - ячейка (`to_cell_id`)
// или короб (`to_load_unit_id`). Ячейку короба устройство не шлёт: сервер знает, где он лежит.
type movementSubmitPayload struct {
	MovementID   string `json:"movement_id"`
	MovementKind string `json:"movement_kind"` // move | replenish
	WarehouseID  string `json:"warehouse_id"`
	Lines        []struct {
		LoadUnitID     string          `json:"load_unit_id"`
		GoodID         string          `json:"good_id"`
		ProductionDate string          `json:"production_date"`
		Qty            decimal.Decimal `json:"qty"`
		FromCellID     string          `json:"from_cell_id"`
		FromLoadUnitID string          `json:"from_load_unit_id"`
		ToCellID       string          `json:"to_cell_id"`
		ToLoadUnitID   string          `json:"to_load_unit_id"`
		// Склад россыпи-источника (P6-07-1); пусто - «Основной». Прежние клиенты его не шлют.
		InternalWarehouseID string `json:"internal_warehouse_id"`
		// КИ марок ЧЗ строки товара (CZ-06), по одной на единицу. Прежние клиенты не шлют.
		Marks []string `json:"marks"`
	} `json:"lines"`
}

// movementSubmit разбирает и проверяет документ движения из очереди устройства (P6-03).
//
// Всё, что проверяется без базы, проверяется здесь: идентификаторы по форме, «ГЕ или товар»,
// ровно один источник и один приёмник у товара, количество и дата. Ошибка формы - отказ по
// существу, и лучше получить его до открытия транзакции. Автор - из токена, а не из тела.
func (s *OperationsService) movementSubmit(ctx context.Context, userID, id string, raw json.RawMessage) (repository.Applied, error) {
	var p movementSubmitPayload
	if err := json.Unmarshal(raw, &p); err != nil {
		return repository.Applied{}, model.ErrInvalidPayload
	}
	in := repository.MovementSubmitInput{
		MovementID:  strings.TrimSpace(p.MovementID),
		Kind:        strings.TrimSpace(p.MovementKind),
		WarehouseID: strings.TrimSpace(p.WarehouseID),
		CreatedBy:   userID,
	}
	if !isUUID(in.MovementID) {
		return repository.Applied{}, model.ErrInvalidMovementID
	}
	if in.WarehouseID == "" {
		return repository.Applied{}, model.ErrEmptyWarehouse
	}
	if !isUUID(in.WarehouseID) {
		return repository.Applied{}, model.ErrInvalidPayload
	}
	if len(p.Lines) == 0 {
		return repository.Applied{}, model.ErrEmptyMovement
	}

	for _, ln := range p.Lines {
		line := repository.MovementLineInput{
			LoadUnitID:     strings.TrimSpace(ln.LoadUnitID),
			GoodID:         strings.TrimSpace(ln.GoodID),
			Qty:            ln.Qty,
			FromCellID:     strings.TrimSpace(ln.FromCellID),
			FromLoadUnitID: strings.TrimSpace(ln.FromLoadUnitID),
			ToCellID:       strings.TrimSpace(ln.ToCellID),
			ToLoadUnitID:   strings.TrimSpace(ln.ToLoadUnitID),

			InternalWarehouseID: strings.TrimSpace(ln.InternalWarehouseID),
		}
		// Все идентификаторы строки - UUID или пусто: мусор в них - ошибка формы.
		for _, v := range []string{line.FromCellID, line.FromLoadUnitID, line.ToCellID, line.ToLoadUnitID, line.GoodID, line.InternalWarehouseID} {
			if v != "" && !isUUID(v) {
				return repository.Applied{}, model.ErrInvalidPayload
			}
		}

		if line.LoadUnitID != "" {
			// ГЕ целиком: товарные поля и источник у такой строки - противоречие, а не подсказка.
			if !isUUID(line.LoadUnitID) {
				return repository.Applied{}, model.ErrInvalidLoadUnitID
			}
			// Склад у короба свой (P6-07-1): из строки его не берём.
			if line.GoodID != "" || ln.ProductionDate != "" || !ln.Qty.IsZero() ||
				line.FromCellID != "" || line.FromLoadUnitID != "" || line.ToLoadUnitID != "" ||
				line.InternalWarehouseID != "" || len(ln.Marks) > 0 {
				return repository.Applied{}, model.ErrInvalidPayload
			}
			if line.ToCellID == "" {
				return repository.Applied{}, model.ErrEmptyCell
			}
			in.Lines = append(in.Lines, line)
			continue
		}

		if line.GoodID == "" {
			return repository.Applied{}, model.ErrEmptyGoodID
		}
		if (line.FromCellID == "") == (line.FromLoadUnitID == "") ||
			(line.ToCellID == "") == (line.ToLoadUnitID == "") {
			return repository.Applied{}, model.ErrEmptyMovementLine
		}
		if !ln.Qty.IsPositive() {
			return repository.Applied{}, model.ErrInvalidQuantity
		}
		iso, err := parseEntryDate(ln.ProductionDate)
		if err != nil {
			return repository.Applied{}, err
		}
		line.ProductionDate = iso
		if line.Marks, err = lineMarks(ln.Marks); err != nil {
			return repository.Applied{}, err
		}
		in.Lines = append(in.Lines, line)
	}
	return s.repo.MovementSubmit(ctx, id, in)
}
