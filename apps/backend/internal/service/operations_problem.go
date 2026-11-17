package service

import (
	"context"
	"encoding/json"
	"strings"
	"unicode/utf8"

	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// problemCommentMax - предел комментария в символах: это пояснение кладовщика, не акт.
const problemCommentMax = 1000

// problemSubmitPayload - тело операции problem_submit, как его собирает устройство (P6-07-1).
//
// Помечено ровно одно: короб целиком (`load_unit_id`) ЛИБО товар (`good_id` + `production_date`
// + `qty`) - из россыпи ячейки (`cell_id`, склад россыпи - `internal_warehouse_id`, пусто -
// «Основной») или из короба (`from_load_unit_id`). Куда - `to_internal_warehouse_id`.
type problemSubmitPayload struct {
	ProblemID   string `json:"problem_id"`
	WarehouseID string `json:"warehouse_id"`

	LoadUnitID string `json:"load_unit_id"`

	GoodID              string          `json:"good_id"`
	ProductionDate      string          `json:"production_date"`
	Qty                 decimal.Decimal `json:"qty"`
	CellID              string          `json:"cell_id"`
	FromLoadUnitID      string          `json:"from_load_unit_id"`
	InternalWarehouseID string          `json:"internal_warehouse_id"`

	ToInternalWarehouseID string `json:"to_internal_warehouse_id"`
	Reason                string `json:"reason"`
	Comment               string `json:"comment"`
	Mark                  string `json:"mark"`
	// КИ марок ЧЗ помеченного товара (CZ-06), по одной на единицу. Прежние клиенты не шлют.
	Marks []string `json:"marks"`
}

// problemSubmit разбирает и проверяет проблему склада из очереди устройства (P6-07-1).
//
// Всё, что проверяется без базы, проверяется здесь: идентификаторы, «короб или товар», один
// источник у товара, количество, дата, причина и комментарий. Автор - из токена.
func (s *OperationsService) problemSubmit(ctx context.Context, userID, id string, raw json.RawMessage) (repository.Applied, error) {
	var p problemSubmitPayload
	if err := json.Unmarshal(raw, &p); err != nil {
		return repository.Applied{}, model.ErrInvalidPayload
	}
	in := repository.ProblemSubmitInput{
		ProblemID:               strings.TrimSpace(p.ProblemID),
		WarehouseID:             strings.TrimSpace(p.WarehouseID),
		CreatedBy:               userID,
		LoadUnitID:              strings.TrimSpace(p.LoadUnitID),
		GoodID:                  strings.TrimSpace(p.GoodID),
		Qty:                     p.Qty,
		CellID:                  strings.TrimSpace(p.CellID),
		FromLoadUnitID:          strings.TrimSpace(p.FromLoadUnitID),
		FromInternalWarehouseID: strings.TrimSpace(p.InternalWarehouseID),
		ToInternalWarehouseID:   strings.TrimSpace(p.ToInternalWarehouseID),
		Reason:                  strings.TrimSpace(p.Reason),
		Comment:                 strings.TrimSpace(p.Comment),
		Mark:                    strings.TrimSpace(p.Mark),
	}
	if !isUUID(in.ProblemID) {
		return repository.Applied{}, model.ErrInvalidProblemID
	}
	if in.WarehouseID == "" {
		return repository.Applied{}, model.ErrEmptyWarehouse
	}
	if !isUUID(in.WarehouseID) || !isUUID(in.ToInternalWarehouseID) {
		return repository.Applied{}, model.ErrInvalidPayload
	}
	for _, v := range []string{in.LoadUnitID, in.GoodID, in.CellID, in.FromLoadUnitID, in.FromInternalWarehouseID} {
		if !isOptionalUUID(v) {
			return repository.Applied{}, model.ErrInvalidPayload
		}
	}
	// Причину и обязательность комментария знает справочник - их проверяет репозиторий.
	if in.Reason == "" {
		return repository.Applied{}, model.ErrUnknownReason
	}
	if utf8.RuneCountInString(in.Comment) > problemCommentMax {
		return repository.Applied{}, model.ErrInvalidPayload
	}

	if in.LoadUnitID != "" {
		// Короб целиком: товарные поля и источник - противоречие, а не подсказка.
		if in.GoodID != "" || p.ProductionDate != "" || !p.Qty.IsZero() ||
			in.CellID != "" || in.FromLoadUnitID != "" || in.FromInternalWarehouseID != "" ||
			len(p.Marks) > 0 {
			return repository.Applied{}, model.ErrInvalidPayload
		}
		return s.repo.ProblemSubmit(ctx, id, in)
	}

	if in.GoodID == "" || (in.CellID == "") == (in.FromLoadUnitID == "") {
		return repository.Applied{}, model.ErrEmptyProblem
	}
	// Склад товара из короба - склад короба: из строки его не берём.
	if in.FromLoadUnitID != "" && in.FromInternalWarehouseID != "" {
		return repository.Applied{}, model.ErrInvalidPayload
	}
	if !p.Qty.IsPositive() {
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
	return s.repo.ProblemSubmit(ctx, id, in)
}
