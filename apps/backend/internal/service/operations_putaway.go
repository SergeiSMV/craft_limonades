package service

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/shopspring/decimal"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// putawaySubmitPayload - тело операции putaway_submit, как его собирает устройство (P5-02).
//
// Строка - короб (`load_unit_id`) ЛИБО россыпь (`good_id` + `production_date` + `qty`);
// `to_cell_id` обязателен у обеих. Ячейку-источник устройство не шлёт: короб берётся оттуда,
// где числится, россыпь - из ячейки приёмки склада.
type putawaySubmitPayload struct {
	PutawayID   string `json:"putaway_id"`
	TaskID      string `json:"task_id"`
	WarehouseID string `json:"warehouse_id"`
	Lines       []struct {
		LoadUnitID     string          `json:"load_unit_id"`
		GoodID         string          `json:"good_id"`
		ProductionDate string          `json:"production_date"`
		Qty            decimal.Decimal `json:"qty"`
		ToCellID       string          `json:"to_cell_id"`
		// КИ марок ЧЗ строки россыпи (CZ-06), по одной на единицу. Прежние клиенты не шлют.
		Marks []string `json:"marks"`
	} `json:"lines"`
}

// putawaySubmit разбирает и проверяет сеанс размещения из очереди устройства (P5-02).
//
// Всё, что проверяется без базы, проверяется здесь: идентификаторы по форме, «короб или
// россыпь», количества и даты. Ошибка формы - отказ по существу, и лучше получить его до
// открытия транзакции. Автор - из токена, а не из тела.
func (s *OperationsService) putawaySubmit(ctx context.Context, userID, id string, raw json.RawMessage) (repository.Applied, error) {
	var p putawaySubmitPayload
	if err := json.Unmarshal(raw, &p); err != nil {
		return repository.Applied{}, model.ErrInvalidPayload
	}
	in := repository.PutawaySubmitInput{
		PutawayID:   strings.TrimSpace(p.PutawayID),
		TaskID:      strings.TrimSpace(p.TaskID),
		WarehouseID: strings.TrimSpace(p.WarehouseID),
		CreatedBy:   userID,
	}
	if !isUUID(in.PutawayID) {
		return repository.Applied{}, model.ErrInvalidPutawayID
	}
	if !isUUID(in.TaskID) {
		return repository.Applied{}, model.ErrInvalidTaskID
	}
	if in.WarehouseID == "" {
		return repository.Applied{}, model.ErrEmptyWarehouse
	}
	if !isUUID(in.WarehouseID) {
		return repository.Applied{}, model.ErrInvalidPayload
	}
	if len(p.Lines) == 0 {
		return repository.Applied{}, model.ErrEmptyPutaway
	}

	for _, ln := range p.Lines {
		toCell := strings.TrimSpace(ln.ToCellID)
		luID := strings.TrimSpace(ln.LoadUnitID)
		goodID := strings.TrimSpace(ln.GoodID)
		if toCell == "" {
			return repository.Applied{}, model.ErrEmptyCell
		}
		if !isUUID(toCell) {
			return repository.Applied{}, model.ErrInvalidPayload
		}

		if luID != "" {
			// Короб: товарные поля у строки-короба - противоречие, а не подсказка.
			if !isUUID(luID) {
				return repository.Applied{}, model.ErrInvalidLoadUnitID
			}
			if goodID != "" || ln.ProductionDate != "" || !ln.Qty.IsZero() || len(ln.Marks) > 0 {
				return repository.Applied{}, model.ErrInvalidPayload
			}
			in.Lines = append(in.Lines, repository.PutawayLineInput{LoadUnitID: luID, ToCellID: toCell})
			continue
		}

		if goodID == "" {
			return repository.Applied{}, model.ErrEmptyGoodID
		}
		if !isUUID(goodID) {
			return repository.Applied{}, model.ErrInvalidPayload
		}
		if !ln.Qty.IsPositive() {
			return repository.Applied{}, model.ErrInvalidQuantity
		}
		iso, err := parseEntryDate(ln.ProductionDate)
		if err != nil {
			return repository.Applied{}, err
		}
		marks, err := lineMarks(ln.Marks)
		if err != nil {
			return repository.Applied{}, err
		}
		in.Lines = append(in.Lines, repository.PutawayLineInput{
			GoodID: goodID, ProductionDate: iso, Qty: ln.Qty, ToCellID: toCell, Marks: marks,
		})
	}
	return s.repo.PutawaySubmit(ctx, id, in)
}
