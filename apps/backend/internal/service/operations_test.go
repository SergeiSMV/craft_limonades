package service

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"craftwms/internal/repository"
)

// fakeOpsRepo — in-memory применение операций: помнит, какие operation_id уже видел, и
// повторяет договор настоящего репозитория (повтор → Duplicate, эффект не выполняется).
type fakeOpsRepo struct {
	seen     map[string]bool
	binds    []repository.BarcodeBindInput
	unbinds  []string
	bindErr  error // ошибка, которую вернуть на привязку
	failWith error // временная ошибка (прерывает батч)
}

func newFakeOpsRepo() *fakeOpsRepo {
	return &fakeOpsRepo{seen: map[string]bool{}}
}

func (f *fakeOpsRepo) BindBarcode(_ context.Context, operationID string, in repository.BarcodeBindInput) (repository.Applied, error) {
	if f.failWith != nil {
		return repository.Applied{}, f.failWith
	}
	if f.seen[operationID] {
		return repository.Applied{Result: json.RawMessage(`{}`), Duplicate: true}, nil
	}
	if f.bindErr != nil {
		return repository.Applied{}, f.bindErr
	}
	f.seen[operationID] = true
	f.binds = append(f.binds, in)
	return repository.Applied{Result: json.RawMessage(`{}`)}, nil
}

func (f *fakeOpsRepo) UnbindBarcode(_ context.Context, operationID, barcode string) (repository.Applied, error) {
	if f.failWith != nil {
		return repository.Applied{}, f.failWith
	}
	if f.seen[operationID] {
		return repository.Applied{Result: json.RawMessage(`{}`), Duplicate: true}, nil
	}
	f.seen[operationID] = true
	f.unbinds = append(f.unbinds, barcode)
	return repository.Applied{Result: json.RawMessage(`{}`)}, nil
}

func (f *fakeOpsRepo) StockEntryStart(_ context.Context, operationID, sessionID, _, _ string) (repository.Applied, error) {
	if f.seen[operationID] {
		return repository.Applied{Result: json.RawMessage(`{}`), Duplicate: true}, nil
	}
	f.seen[operationID] = true
	return repository.Applied{Result: json.RawMessage(`{"session_id":"` + sessionID + `"}`)}, nil
}

func (f *fakeOpsRepo) StockEntryCheckpoint(_ context.Context, operationID, _, _ string, _ []repository.StockEntryLineInput, _ []repository.BarcodeBindInput) (repository.Applied, error) {
	if f.seen[operationID] {
		return repository.Applied{Result: json.RawMessage(`{}`), Duplicate: true}, nil
	}
	f.seen[operationID] = true
	return repository.Applied{Result: json.RawMessage(`{}`)}, nil
}

func (f *fakeOpsRepo) StockEntryFinalize(_ context.Context, operationID, _ string) (repository.Applied, error) {
	if f.seen[operationID] {
		return repository.Applied{Result: json.RawMessage(`{}`), Duplicate: true}, nil
	}
	f.seen[operationID] = true
	return repository.Applied{Result: json.RawMessage(`{}`)}, nil
}

// op собирает операцию батча с телом-картой.
func op(id, kind string, payload map[string]any) Operation {
	body, _ := json.Marshal(payload)
	return Operation{OperationID: id, Kind: kind, Payload: body}
}

const (
	opUserID = "99999999-9999-4999-8999-999999999999"
	opID1    = "11111111-1111-4111-8111-111111111111"
	opID2    = "22222222-2222-4222-8222-222222222222"
)

// Повтор той же операции не выполняет эффект второй раз — главный критерий P2-05.
func TestOperations_repeatDoesNotDoubleApply(t *testing.T) {
	repo := newFakeOpsRepo()
	svc := NewOperationsService(repo)
	batch := []Operation{op(opID1, repository.KindBindBarcode, map[string]any{
		"good_id": "g1", "barcode": "4607044662964",
	})}

	first, err := svc.Apply(context.Background(), opUserID, batch)
	if err != nil {
		t.Fatalf("первый батч: %v", err)
	}
	if first[0].Status != StatusAccepted {
		t.Fatalf("первая попытка: ждали %q, получили %q", StatusAccepted, first[0].Status)
	}

	second, err := svc.Apply(context.Background(), opUserID, batch)
	if err != nil {
		t.Fatalf("повтор батча: %v", err)
	}
	if second[0].Status != StatusDuplicate {
		t.Fatalf("повтор: ждали %q, получили %q", StatusDuplicate, second[0].Status)
	}
	if len(repo.binds) != 1 {
		t.Fatalf("эффект применён %d раз, ждали 1", len(repo.binds))
	}
}

// Отказ по существу не роняет батч и не мешает следующим операциям.
func TestOperations_rejectionDoesNotStopBatch(t *testing.T) {
	repo := newFakeOpsRepo()
	repo.bindErr = repository.ErrBarcodeConflict
	svc := NewOperationsService(repo)

	results, err := svc.Apply(context.Background(), opUserID, []Operation{
		op(opID1, repository.KindBindBarcode, map[string]any{"good_id": "g1", "barcode": "111"}),
		op(opID2, repository.KindUnbindBarcode, map[string]any{"barcode": "222"}),
	})
	if err != nil {
		t.Fatalf("батч: %v", err)
	}
	if len(results) != 2 {
		t.Fatalf("ждали 2 результата, получили %d", len(results))
	}
	if results[0].Status != StatusRejected {
		t.Fatalf("первая: ждали %q, получили %q", StatusRejected, results[0].Status)
	}
	if results[0].Error == "" {
		t.Fatal("у отклонённой операции пустая причина — на экране разбора показывать нечего")
	}
	if results[1].Status != StatusAccepted {
		t.Fatalf("вторая: ждали %q, получили %q", StatusAccepted, results[1].Status)
	}
}

// Временная неудача обрывает батч: применённое возвращается, остальное устройство пришлёт снова.
// Перескакивать через застрявшую операцию нельзя — порядок «привязать/отвязать» решает исход.
func TestOperations_temporaryFailureTruncatesBatch(t *testing.T) {
	repo := newFakeOpsRepo()
	svc := NewOperationsService(repo)

	// Первая операция проходит, затем репозиторий начинает падать.
	first, err := svc.Apply(context.Background(), opUserID, []Operation{
		op(opID1, repository.KindBindBarcode, map[string]any{"good_id": "g1", "barcode": "111"}),
	})
	if err != nil || first[0].Status != StatusAccepted {
		t.Fatalf("подготовка: %v / %+v", err, first)
	}

	repo.failWith = errors.New("connection reset")
	results, err := svc.Apply(context.Background(), opUserID, []Operation{
		op(opID1, repository.KindBindBarcode, map[string]any{"good_id": "g1", "barcode": "111"}),
		op(opID2, repository.KindUnbindBarcode, map[string]any{"barcode": "222"}),
	})
	if err == nil {
		t.Fatal("ждали временную ошибку на первой же операции")
	}
	if results != nil {
		t.Fatalf("ничего не применено — результатов быть не должно, получили %+v", results)
	}
}

// Неизвестный тип операции отклоняется, а не считается временной неудачей: иначе очередь
// устройства встала бы на нём навсегда.
func TestOperations_unknownKindIsRejected(t *testing.T) {
	svc := NewOperationsService(newFakeOpsRepo())
	results, err := svc.Apply(context.Background(), opUserID, []Operation{
		op(opID1, "teleport_goods", map[string]any{}),
	})
	if err != nil {
		t.Fatalf("батч: %v", err)
	}
	if results[0].Status != StatusRejected {
		t.Fatalf("ждали %q, получили %q", StatusRejected, results[0].Status)
	}
}

// operation_id не UUID — отказ по существу: генерировать его заново некому.
func TestOperations_invalidOperationIDIsRejected(t *testing.T) {
	svc := NewOperationsService(newFakeOpsRepo())
	results, err := svc.Apply(context.Background(), opUserID, []Operation{
		op("не-uuid", repository.KindBindBarcode, map[string]any{"good_id": "g", "barcode": "1"}),
	})
	if err != nil {
		t.Fatalf("батч: %v", err)
	}
	if results[0].Status != StatusRejected {
		t.Fatalf("ждали %q, получили %q", StatusRejected, results[0].Status)
	}
}

// Границы батча: пустой и переполненный отвергаются целиком.
func TestOperations_batchBounds(t *testing.T) {
	svc := NewOperationsService(newFakeOpsRepo())

	if _, err := svc.Apply(context.Background(), opUserID, nil); !errors.Is(err, ErrEmptyBatch) {
		t.Fatalf("пустой батч: ждали ErrEmptyBatch, получили %v", err)
	}

	tooMany := make([]Operation, MaxBatchOperations+1)
	for i := range tooMany {
		tooMany[i] = op(opID1, repository.KindBindBarcode, map[string]any{"good_id": "g", "barcode": "1"})
	}
	if _, err := svc.Apply(context.Background(), opUserID, tooMany); !errors.Is(err, ErrBatchTooLarge) {
		t.Fatalf("переполненный батч: ждали ErrBatchTooLarge, получили %v", err)
	}
}

// Пустые обязательные поля тела — отказ по существу, а не паника на nil.
func TestOperations_emptyPayloadFieldsRejected(t *testing.T) {
	svc := NewOperationsService(newFakeOpsRepo())
	results, err := svc.Apply(context.Background(), opUserID, []Operation{
		op(opID1, repository.KindBindBarcode, map[string]any{"good_id": "", "barcode": "1"}),
		op(opID2, repository.KindUnbindBarcode, map[string]any{"barcode": "  "}),
	})
	if err != nil {
		t.Fatalf("батч: %v", err)
	}
	for i, r := range results {
		if r.Status != StatusRejected {
			t.Fatalf("операция %d: ждали %q, получили %q", i, StatusRejected, r.Status)
		}
	}
}
