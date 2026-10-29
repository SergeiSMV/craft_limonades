package service

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// fakeOpsRepo — in-memory применение операций: помнит, какие operation_id уже видел, и
// повторяет договор настоящего репозитория (повтор → Duplicate, эффект не выполняется).
type fakeOpsRepo struct {
	seen     map[string]bool
	binds    []repository.BarcodeBindInput
	unbinds  []string
	receipts []repository.ReceiptSubmitInput
	putaways []repository.PutawaySubmitInput
	moves    []repository.MovementSubmitInput
	problems []repository.ProblemSubmitInput
	returns  []repository.ReturnSubmitInput
	counts   []model.StocktakeCellSubmitInput
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

func (f *fakeOpsRepo) StockEntryCheckpoint(_ context.Context, operationID, _ string, _ repository.StockEntryCellInput) (repository.Applied, error) {
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

func (f *fakeOpsRepo) ReceiptSubmit(_ context.Context, operationID string, in repository.ReceiptSubmitInput) (repository.Applied, error) {
	if f.seen[operationID] {
		return repository.Applied{Result: json.RawMessage(`{}`), Duplicate: true}, nil
	}
	f.seen[operationID] = true
	f.receipts = append(f.receipts, in)
	return repository.Applied{Result: json.RawMessage(`{}`)}, nil
}

func (f *fakeOpsRepo) PutawaySubmit(_ context.Context, operationID string, in repository.PutawaySubmitInput) (repository.Applied, error) {
	if f.seen[operationID] {
		return repository.Applied{Result: json.RawMessage(`{}`), Duplicate: true}, nil
	}
	f.seen[operationID] = true
	f.putaways = append(f.putaways, in)
	return repository.Applied{Result: json.RawMessage(`{}`)}, nil
}

func (f *fakeOpsRepo) MovementSubmit(_ context.Context, operationID string, in repository.MovementSubmitInput) (repository.Applied, error) {
	if f.seen[operationID] {
		return repository.Applied{Result: json.RawMessage(`{}`), Duplicate: true}, nil
	}
	f.seen[operationID] = true
	f.moves = append(f.moves, in)
	return repository.Applied{Result: json.RawMessage(`{}`)}, nil
}

func (f *fakeOpsRepo) StocktakeCellSubmit(_ context.Context, operationID string, in model.StocktakeCellSubmitInput) (repository.Applied, error) {
	if f.seen[operationID] {
		return repository.Applied{Result: json.RawMessage(`{}`), Duplicate: true}, nil
	}
	f.seen[operationID] = true
	f.counts = append(f.counts, in)
	return repository.Applied{Result: json.RawMessage(`{}`)}, nil
}

func (f *fakeOpsRepo) ReturnSubmit(_ context.Context, operationID string, in repository.ReturnSubmitInput) (repository.Applied, error) {
	if f.seen[operationID] {
		return repository.Applied{Result: json.RawMessage(`{}`), Duplicate: true}, nil
	}
	f.seen[operationID] = true
	f.returns = append(f.returns, in)
	return repository.Applied{Result: json.RawMessage(`{}`)}, nil
}

func (f *fakeOpsRepo) ProblemSubmit(_ context.Context, operationID string, in repository.ProblemSubmitInput) (repository.Applied, error) {
	if f.seen[operationID] {
		return repository.Applied{Result: json.RawMessage(`{}`), Duplicate: true}, nil
	}
	f.seen[operationID] = true
	f.problems = append(f.problems, in)
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

// Приёмка (P4-09): ошибки формы отсекаются до репозитория и приходят отказом по существу.
func TestOperations_receiptSubmitValidation(t *testing.T) {
	const (
		receipt   = "33333333-3333-4333-8333-333333333333"
		warehouse = "44444444-4444-4444-8444-444444444444"
		good      = "55555555-5555-4555-8555-555555555555"
	)
	line := func(over map[string]any) map[string]any {
		l := map[string]any{"good_id": good, "production_date": "01-09-2026", "qty": 2}
		for k, v := range over {
			l[k] = v
		}
		return l
	}
	cases := []struct {
		name    string
		payload map[string]any
	}{
		{"id документа не UUID", map[string]any{"doc_number": "ТН-1", "doc_date": "01-10-2026", "receipt_id": "x", "warehouse_id": warehouse, "lines": []any{line(nil)}}},
		{"нет склада", map[string]any{"doc_number": "ТН-1", "doc_date": "01-10-2026", "receipt_id": receipt, "lines": []any{line(nil)}}},
		{"пустой документ", map[string]any{"doc_number": "ТН-1", "doc_date": "01-10-2026", "receipt_id": receipt, "warehouse_id": warehouse}},
		{"нулевое количество", map[string]any{"doc_number": "ТН-1", "doc_date": "01-10-2026", "receipt_id": receipt, "warehouse_id": warehouse, "lines": []any{line(map[string]any{"qty": 0})}}},
		{"неверная дата", map[string]any{"doc_number": "ТН-1", "doc_date": "01-10-2026", "receipt_id": receipt, "warehouse_id": warehouse, "lines": []any{line(map[string]any{"production_date": "2026-09-01"})}}},
		{"ГЕ не UUID", map[string]any{"doc_number": "ТН-1", "doc_date": "01-10-2026", "receipt_id": receipt, "warehouse_id": warehouse, "load_units": []any{map[string]any{"id": "CWLU1:x"}}, "lines": []any{line(nil)}}},
		{"нет накладной", map[string]any{"receipt_id": receipt, "warehouse_id": warehouse, "lines": []any{line(nil)}}},
		{"накладная в будущем", map[string]any{"doc_number": "1", "doc_date": "01-10-2099", "receipt_id": receipt, "warehouse_id": warehouse, "lines": []any{line(nil)}}},
		{"неизвестный вид ГЕ", map[string]any{"doc_number": "ТН-1", "doc_date": "01-10-2026", "receipt_id": receipt, "warehouse_id": warehouse, "load_units": []any{map[string]any{"id": good, "kind": "bag"}}, "lines": []any{line(nil)}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			repo := newFakeOpsRepo()
			res, err := NewOperationsService(repo).Apply(context.Background(), opUserID,
				[]Operation{op(opID1, repository.KindReceiptSubmit, tc.payload)})
			if err != nil {
				t.Fatalf("Apply: %v", err)
			}
			if res[0].Status != StatusRejected {
				t.Fatalf("ждали rejected, получили %q", res[0].Status)
			}
			if len(repo.receipts) != 0 {
				t.Fatal("неверная приёмка дошла до репозитория")
			}
		})
	}

	// Верная приёмка доходит до репозитория с автором из токена и видом ГЕ по умолчанию.
	repo := newFakeOpsRepo()
	res, err := NewOperationsService(repo).Apply(context.Background(), opUserID, []Operation{
		op(opID2, repository.KindReceiptSubmit, map[string]any{
			"receipt_id": receipt, "warehouse_id": warehouse,
			"doc_number": " ТН-1042/2 ", "doc_date": "01-10-2026",
			"load_units": []any{map[string]any{"id": good}},
			"lines":      []any{line(map[string]any{"load_unit_id": good})},
		}),
	})
	if err != nil || res[0].Status != StatusAccepted {
		t.Fatalf("верная приёмка: err=%v, исход %+v", err, res)
	}
	got := repo.receipts[0]
	if got.Doc.Number != "ТН-1042/2" || got.Doc.Date.Format("02-01-2006") != "01-10-2026" {
		t.Errorf("накладная до репозитория: %+v", got.Doc)
	}
	if got.CreatedBy != opUserID || got.LoadUnits[0].Kind != "box" || got.Lines[0].ProductionDate != "2026-09-01" {
		t.Fatalf("разбор приёмки: %+v", got)
	}
}

// Размещение (P5-02): ошибки формы отсекаются до репозитория и приходят отказом по существу.
func TestOperations_putawaySubmitValidation(t *testing.T) {
	const (
		putaway   = "66666666-6666-4666-8666-666666666666"
		warehouse = "44444444-4444-4444-8444-444444444444"
		good      = "55555555-5555-4555-8555-555555555555"
		box       = "77777777-7777-4777-8777-777777777777"
		cell      = "88888888-8888-4888-8888-888888888888"
		task      = "99999999-0000-4000-8000-000000000001"
	)
	loose := func(over map[string]any) map[string]any {
		l := map[string]any{"good_id": good, "production_date": "01-09-2026", "qty": 2, "to_cell_id": cell}
		for k, v := range over {
			l[k] = v
		}
		return l
	}
	boxLine := map[string]any{"load_unit_id": box, "to_cell_id": cell}
	doc := func(lines ...any) map[string]any {
		return map[string]any{"putaway_id": putaway, "task_id": task, "warehouse_id": warehouse, "lines": lines}
	}
	cases := []struct {
		name    string
		payload map[string]any
	}{
		{"id документа не UUID", map[string]any{"putaway_id": "x", "task_id": task, "warehouse_id": warehouse, "lines": []any{boxLine}}},
		// Размещения без задания нет (P5-02-1).
		{"нет задания", map[string]any{"putaway_id": putaway, "warehouse_id": warehouse, "lines": []any{boxLine}}},
		{"задание не UUID", map[string]any{"putaway_id": putaway, "task_id": "№57", "warehouse_id": warehouse, "lines": []any{boxLine}}},
		{"нет склада", map[string]any{"putaway_id": putaway, "task_id": task, "lines": []any{boxLine}}},
		{"пустой сеанс", map[string]any{"putaway_id": putaway, "task_id": task, "warehouse_id": warehouse}},
		{"нет ячейки назначения", doc(map[string]any{"load_unit_id": box})},
		{"короб не UUID", doc(map[string]any{"load_unit_id": "CWLU1:x", "to_cell_id": cell})},
		// Строка — короб ИЛИ россыпь: товарные поля у короба — противоречие.
		{"короб с товаром", doc(map[string]any{"load_unit_id": box, "good_id": good, "to_cell_id": cell})},
		{"короб с количеством", doc(map[string]any{"load_unit_id": box, "qty": 3, "to_cell_id": cell})},
		{"ни короба, ни товара", doc(map[string]any{"to_cell_id": cell})},
		{"нулевое количество", doc(loose(map[string]any{"qty": 0}))},
		{"неверная дата", doc(loose(map[string]any{"production_date": "2026-09-01"}))},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			repo := newFakeOpsRepo()
			res, err := NewOperationsService(repo).Apply(context.Background(), opUserID,
				[]Operation{op(opID1, repository.KindPutawaySubmit, tc.payload)})
			if err != nil {
				t.Fatalf("Apply: %v", err)
			}
			if res[0].Status != StatusRejected {
				t.Fatalf("ждали rejected, получили %q", res[0].Status)
			}
			if len(repo.putaways) != 0 {
				t.Fatal("неверное размещение дошло до репозитория")
			}
		})
	}

	// Верный сеанс доходит до репозитория с автором из токена и датой в ISO.
	repo := newFakeOpsRepo()
	res, err := NewOperationsService(repo).Apply(context.Background(), opUserID, []Operation{
		op(opID2, repository.KindPutawaySubmit, doc(boxLine, loose(nil))),
	})
	if err != nil || res[0].Status != StatusAccepted {
		t.Fatalf("верное размещение: err=%v, исход %+v", err, res)
	}
	got := repo.putaways[0]
	if got.CreatedBy != opUserID || got.TaskID != task || len(got.Lines) != 2 {
		t.Fatalf("разбор размещения: %+v", got)
	}
	if got.Lines[0].LoadUnitID != box || got.Lines[1].ProductionDate != "2026-09-01" || got.Lines[1].ToCellID != cell {
		t.Fatalf("строки размещения: %+v", got.Lines)
	}
}

// Движение (P6-03): ошибки формы отсекаются до репозитория и приходят отказом по существу.
func TestOperations_movementSubmitValidation(t *testing.T) {
	const (
		movement  = "66666666-6666-4666-8666-666666666667"
		warehouse = "44444444-4444-4444-8444-444444444444"
		good      = "55555555-5555-4555-8555-555555555555"
		box       = "77777777-7777-4777-8777-777777777777"
		box2      = "77777777-7777-4777-8777-777777777778"
		cell      = "88888888-8888-4888-8888-888888888888"
		cell2     = "88888888-8888-4888-8888-888888888889"
	)
	goods := func(over map[string]any) map[string]any {
		l := map[string]any{"good_id": good, "production_date": "01-09-2026", "qty": 2,
			"from_load_unit_id": box, "to_cell_id": cell}
		for k, v := range over {
			if v == nil {
				delete(l, k)
			} else {
				l[k] = v
			}
		}
		return l
	}
	luLine := map[string]any{"load_unit_id": box, "to_cell_id": cell}
	doc := func(lines ...any) map[string]any {
		return map[string]any{"movement_id": movement, "movement_kind": "move", "warehouse_id": warehouse, "lines": lines}
	}
	cases := []struct {
		name    string
		payload map[string]any
	}{
		{"id документа не UUID", map[string]any{"movement_id": "x", "movement_kind": "move", "warehouse_id": warehouse, "lines": []any{luLine}}},
		{"нет склада", map[string]any{"movement_id": movement, "movement_kind": "move", "lines": []any{luLine}}},
		{"пустой документ", map[string]any{"movement_id": movement, "movement_kind": "move", "warehouse_id": warehouse}},
		{"ГЕ без ячейки назначения", doc(map[string]any{"load_unit_id": box})},
		{"ГЕ не UUID", doc(map[string]any{"load_unit_id": "CWLU1:x", "to_cell_id": cell})},
		// Строка — ГЕ ИЛИ товар: товарные поля и источник у ГЕ целиком — противоречие.
		{"ГЕ с товаром", doc(map[string]any{"load_unit_id": box, "good_id": good, "to_cell_id": cell})},
		{"ГЕ с источником", doc(map[string]any{"load_unit_id": box, "from_cell_id": cell2, "to_cell_id": cell})},
		{"ГЕ в короб", doc(map[string]any{"load_unit_id": box, "to_load_unit_id": box2})},
		{"ни ГЕ, ни товара", doc(map[string]any{"to_cell_id": cell})},
		// У товара ровно один источник и один приёмник.
		{"товар без источника", doc(goods(map[string]any{"from_load_unit_id": nil}))},
		{"товар с двумя источниками", doc(goods(map[string]any{"from_cell_id": cell2}))},
		{"товар без приёмника", doc(goods(map[string]any{"to_cell_id": nil}))},
		{"товар с двумя приёмниками", doc(goods(map[string]any{"to_load_unit_id": box2}))},
		{"ячейка не UUID", doc(goods(map[string]any{"to_cell_id": "M1-1-1-1"}))},
		{"нулевое количество", doc(goods(map[string]any{"qty": 0}))},
		{"неверная дата", doc(goods(map[string]any{"production_date": "2026-09-01"}))},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			repo := newFakeOpsRepo()
			res, err := NewOperationsService(repo).Apply(context.Background(), opUserID,
				[]Operation{op(opID1, repository.KindMovementSubmit, tc.payload)})
			if err != nil {
				t.Fatalf("Apply: %v", err)
			}
			if res[0].Status != StatusRejected {
				t.Fatalf("ждали rejected, получили %q", res[0].Status)
			}
			if len(repo.moves) != 0 {
				t.Fatal("неверное движение дошло до репозитория")
			}
		})
	}

	// Верный документ доходит до репозитория с автором из токена, видом и датой в ISO.
	repo := newFakeOpsRepo()
	res, err := NewOperationsService(repo).Apply(context.Background(), opUserID, []Operation{
		op(opID2, repository.KindMovementSubmit, doc(luLine, goods(map[string]any{"to_cell_id": nil, "to_load_unit_id": box2}))),
	})
	if err != nil || res[0].Status != StatusAccepted {
		t.Fatalf("верное движение: err=%v, исход %+v", err, res)
	}
	got := repo.moves[0]
	if got.CreatedBy != opUserID || got.Kind != "move" || len(got.Lines) != 2 {
		t.Fatalf("разбор движения: %+v", got)
	}
	if g := got.Lines[1]; g.FromLoadUnitID != box || g.ToLoadUnitID != box2 || g.ProductionDate != "2026-09-01" {
		t.Fatalf("строка товара: %+v", g)
	}
}

// Проблема склада (P6-07-1): ошибки формы отсекаются до репозитория и приходят отказом по
// существу; верная доходит с автором из токена и датой в ISO.
func TestOperations_problemSubmitValidation(t *testing.T) {
	const (
		problem   = "66666666-6666-4666-8666-666666666668"
		warehouse = "44444444-4444-4444-8444-444444444444"
		defect    = "99999999-9999-4999-8999-999999999999"
		good      = "55555555-5555-4555-8555-555555555555"
		box       = "77777777-7777-4777-8777-777777777777"
		cell      = "88888888-8888-4888-8888-888888888888"
	)
	body := func(over map[string]any) map[string]any {
		p := map[string]any{"problem_id": problem, "warehouse_id": warehouse,
			"to_internal_warehouse_id": defect, "reason": "breakage",
			"good_id": good, "production_date": "01-09-2026", "qty": 2, "cell_id": cell}
		for k, v := range over {
			if v == nil {
				delete(p, k)
			} else {
				p[k] = v
			}
		}
		return p
	}
	wholeBox := body(map[string]any{"good_id": nil, "production_date": nil, "qty": nil, "cell_id": nil, "load_unit_id": box})
	cases := []struct {
		name    string
		payload map[string]any
	}{
		{"id не UUID", body(map[string]any{"problem_id": "x"})},
		{"нет склада", body(map[string]any{"warehouse_id": nil})},
		{"нет склада назначения", body(map[string]any{"to_internal_warehouse_id": nil})},
		// Есть ли причина в справочнике и нужен ли ей комментарий, проверяет репозиторий
		// (ADHOC-55) — интеграционный тест; здесь только пустая причина.
		{"без причины", body(map[string]any{"reason": ""})},
		{"комментарий длиннее предела", body(map[string]any{"comment": strings.Repeat("я", problemCommentMax+1)})},
		{"короб с товаром", map[string]any{"problem_id": problem, "warehouse_id": warehouse,
			"to_internal_warehouse_id": defect, "reason": "breakage", "load_unit_id": box, "good_id": good}},
		{"короб со складом россыпи", body(map[string]any{"good_id": nil, "production_date": nil, "qty": nil,
			"cell_id": nil, "load_unit_id": box, "internal_warehouse_id": defect})},
		{"товар без источника", body(map[string]any{"cell_id": nil})},
		{"товар с двумя источниками", body(map[string]any{"from_load_unit_id": box})},
		{"из короба со складом строки", body(map[string]any{"cell_id": nil, "from_load_unit_id": box, "internal_warehouse_id": defect})},
		{"нулевое количество", body(map[string]any{"qty": 0})},
		{"неверная дата", body(map[string]any{"production_date": "2026-09-01"})},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			repo := newFakeOpsRepo()
			res, err := NewOperationsService(repo).Apply(context.Background(), opUserID,
				[]Operation{op(opID1, repository.KindProblemSubmit, tc.payload)})
			if err != nil {
				t.Fatalf("Apply: %v", err)
			}
			if res[0].Status != StatusRejected {
				t.Fatalf("ждали rejected, получили %q", res[0].Status)
			}
			if len(repo.problems) != 0 {
				t.Fatal("неверная проблема дошла до репозитория")
			}
		})
	}

	repo := newFakeOpsRepo()
	res, err := NewOperationsService(repo).Apply(context.Background(), opUserID, []Operation{
		op(opID1, repository.KindProblemSubmit, body(map[string]any{"reason": "other", "comment": " развакуум "})),
		op(opID2, repository.KindProblemSubmit, wholeBox),
	})
	if err != nil || res[0].Status != StatusAccepted || res[1].Status != StatusAccepted {
		t.Fatalf("верные проблемы: err=%v, исход %+v", err, res)
	}
	if g := repo.problems[0]; g.CreatedBy != opUserID || g.ProductionDate != "2026-09-01" ||
		g.CellID != cell || g.Comment != "развакуум" || g.ToInternalWarehouseID != defect {
		t.Fatalf("разбор товара: %+v", g)
	}
	if g := repo.problems[1]; g.LoadUnitID != box || g.GoodID != "" {
		t.Fatalf("разбор короба: %+v", g)
	}
}
