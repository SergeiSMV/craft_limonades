package service

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	"craftwms/internal/repository"
)

// ErrInvalidShipmentID — идентификатор сеанса отгрузки возврата не UUID (ADHOC-31).
var ErrInvalidShipmentID = errors.New("shipment id must be a UUID")

// returnSubmitPayload — тело операции return_submit, как его собирает устройство (ADHOC-31):
// сеанс отгрузки по заданию возврата — какие позиции (проблемы) отгружены. Позиция — целиком,
// поэтому ни количества, ни ячеек в теле нет. Марки ЧЗ (CZ-06, долг 30) — отсканированные
// экземпляры позиций россыпью; прежние клиенты их не шлют.
type returnSubmitPayload struct {
	ShipmentID  string   `json:"shipment_id"`
	TaskID      string   `json:"task_id"`
	WarehouseID string   `json:"warehouse_id"`
	ProblemIDs  []string `json:"problem_ids"`
	Marks       []string `json:"marks"`
}

// returnSubmit разбирает и проверяет сеанс отгрузки возврата из очереди устройства. Автор —
// из токена; всё, что проверяется без базы, — здесь.
func (s *OperationsService) returnSubmit(ctx context.Context, userID, id string, raw json.RawMessage) (repository.Applied, error) {
	var p returnSubmitPayload
	if err := json.Unmarshal(raw, &p); err != nil {
		return repository.Applied{}, ErrInvalidPayload
	}
	in := repository.ReturnSubmitInput{
		ShipmentID:  strings.TrimSpace(p.ShipmentID),
		TaskID:      strings.TrimSpace(p.TaskID),
		WarehouseID: strings.TrimSpace(p.WarehouseID),
		CreatedBy:   userID,
	}
	if !isUUID(in.ShipmentID) {
		return repository.Applied{}, ErrInvalidShipmentID
	}
	if in.WarehouseID == "" {
		return repository.Applied{}, ErrEmptyWarehouse
	}
	if !isUUID(in.TaskID) {
		return repository.Applied{}, ErrInvalidTaskID
	}
	if !isUUID(in.WarehouseID) {
		return repository.Applied{}, ErrInvalidPayload
	}
	if len(p.ProblemIDs) == 0 {
		return repository.Applied{}, repository.ErrEmptyShipment
	}
	for _, pid := range p.ProblemIDs {
		pid = strings.TrimSpace(pid)
		if !isUUID(pid) {
			return repository.Applied{}, ErrInvalidPayload
		}
		in.ProblemIDs = append(in.ProblemIDs, pid)
	}
	marks, err := lineMarks(p.Marks)
	if err != nil {
		return repository.Applied{}, err
	}
	in.Marks = marks
	return s.repo.ReturnSubmit(ctx, id, in)
}
