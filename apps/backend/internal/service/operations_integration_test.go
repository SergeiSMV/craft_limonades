package service_test

import (
	"context"
	"encoding/json"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/shopspring/decimal"

	"craftwms/internal/repository"
	"craftwms/internal/service"
	"craftwms/internal/testutil"
)

// newOperationsSvc собирает сервис приёма батча на реальном пуле.
func newOperationsSvc(pool *pgxpool.Pool) *service.OperationsService {
	return service.NewOperationsService(repository.NewOperationsRepository(pool))
}

// opWith собирает операцию батча с телом-картой.
func opWith(id, kind string, payload map[string]any) service.Operation {
	body, _ := json.Marshal(payload)
	return service.Operation{OperationID: id, Kind: kind, Payload: body}
}

// testUser — автор операций в тестах, где он не проверяется (привязки ШК его не используют).
const testUser = "00000000-0000-4000-8000-000000000001"

// writtenIn достаёт поле written из ответа финала.
func writtenIn(t *testing.T, raw json.RawMessage) int {
	t.Helper()
	var body struct {
		Written int `json:"written"`
	}
	if err := json.Unmarshal(raw, &body); err != nil {
		t.Fatalf("разбор ответа финала %s: %v", raw, err)
	}
	return body.Written
}

// countBarcodes — сколько привязок с таким кодом лежит в базе.
func countBarcodes(t *testing.T, pool *pgxpool.Pool, code string) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(context.Background(),
		`SELECT count(*) FROM barcodes WHERE barcode = $1`, code).Scan(&n); err != nil {
		t.Fatalf("count barcodes: %v", err)
	}
	return n
}

// Критерий P2-05: переотправка операции не двоит данные — проверяется на реальной БД.
func TestOperations_replayIsIdempotent(t *testing.T) {
	pool := testutil.StartPostgres(t)
	svc := newOperationsSvc(pool)
	ctx := context.Background()

	good := seedGood(t, pool, "Снек")
	const opID = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
	batch := []service.Operation{opWith(opID, repository.KindBindBarcode, map[string]any{
		"good_id": good, "barcode": "4600000000031", "symbology": "ean13",
	})}

	first, err := svc.Apply(ctx, testUser, batch)
	if err != nil {
		t.Fatalf("первая отправка: %v", err)
	}
	if first[0].Status != service.StatusAccepted {
		t.Fatalf("первая: ждали accepted, получили %q (%s)", first[0].Status, first[0].Error)
	}

	// Та же операция приходит снова — так ведёт себя очередь после оборванного ответа.
	second, err := svc.Apply(ctx, testUser, batch)
	if err != nil {
		t.Fatalf("переотправка: %v", err)
	}
	if second[0].Status != service.StatusDuplicate {
		t.Fatalf("переотправка: ждали duplicate, получили %q", second[0].Status)
	}

	// Журнал знает операцию ровно один раз.
	var marks int
	if err := pool.QueryRow(ctx,
		`SELECT count(*) FROM processed_operations WHERE operation_id = $1::uuid`, opID).Scan(&marks); err != nil {
		t.Fatalf("count processed: %v", err)
	}
	if marks != 1 {
		t.Fatalf("в журнале %d отметок операции, ждали 1", marks)
	}
}

// Отвязка через очередь: повтор не воскрешает и не двоит. Проверяем на паре bind→unbind,
// потому что именно их порядок ломается, если батч перескакивает застрявшую операцию.
func TestOperations_unbindReplayKeepsResult(t *testing.T) {
	pool := testutil.StartPostgres(t)
	svc := newOperationsSvc(pool)
	ctx := context.Background()

	good := seedGood(t, pool, "Кальмары")
	const code = "4600000000048"
	const bindID = "bbbbbbbb-1111-4111-8111-bbbbbbbbbbbb"
	const unbindID = "cccccccc-1111-4111-8111-cccccccccccc"

	batch := []service.Operation{
		opWith(bindID, repository.KindBindBarcode, map[string]any{"good_id": good, "barcode": code}),
		opWith(unbindID, repository.KindUnbindBarcode, map[string]any{"barcode": code}),
	}
	results, err := svc.Apply(ctx, testUser, batch)
	if err != nil {
		t.Fatalf("батч: %v", err)
	}
	for i, r := range results {
		if r.Status != service.StatusAccepted {
			t.Fatalf("операция %d: ждали accepted, получили %q (%s)", i, r.Status, r.Error)
		}
	}
	if n := countBarcodes(t, pool, code); n != 0 {
		t.Fatalf("после bind+unbind привязок %d, ждали 0", n)
	}

	// Повтор всего батча: обе операции уже применялись — привязка НЕ должна воскреснуть.
	replay, err := svc.Apply(ctx, testUser, batch)
	if err != nil {
		t.Fatalf("повтор батча: %v", err)
	}
	for i, r := range replay {
		if r.Status != service.StatusDuplicate {
			t.Fatalf("повтор операции %d: ждали duplicate, получили %q", i, r.Status)
		}
	}
	if n := countBarcodes(t, pool, code); n != 0 {
		t.Fatalf("повтор воскресил привязку: %d, ждали 0", n)
	}
}

// Две параллельные попытки с одним operation_id: эффект применяется ровно один раз.
// Сериализацию делает уникальный индекс журнала — отдельной блокировки в коде нет, и это
// проверяется здесь, а не принимается на веру.
func TestOperations_concurrentReplayAppliesOnce(t *testing.T) {
	pool := testutil.StartPostgres(t)
	svc := newOperationsSvc(pool)
	ctx := context.Background()

	good := seedGood(t, pool, "Арахис")
	const opID = "dddddddd-1111-4111-8111-dddddddddddd"
	const code = "4600000000055"
	batch := []service.Operation{opWith(opID, repository.KindBindBarcode, map[string]any{
		"good_id": good, "barcode": code,
	})}

	const racers = 8
	var wg sync.WaitGroup
	statuses := make([]string, racers)
	errs := make([]error, racers)
	wg.Add(racers)
	for i := range racers {
		go func(i int) {
			defer wg.Done()
			res, err := svc.Apply(ctx, testUser, batch)
			if err != nil {
				errs[i] = err
				return
			}
			statuses[i] = res[0].Status
		}(i)
	}
	wg.Wait()

	accepted := 0
	for i, st := range statuses {
		if errs[i] != nil {
			t.Fatalf("параллельная попытка %d упала: %v", i, errs[i])
		}
		switch st {
		case service.StatusAccepted:
			accepted++
		case service.StatusDuplicate:
		default:
			t.Fatalf("попытка %d: неожиданный статус %q", i, st)
		}
	}
	if accepted != 1 {
		t.Fatalf("операцию применили %d раз, ждали ровно 1", accepted)
	}
	if n := countBarcodes(t, pool, code); n != 1 {
		t.Fatalf("привязок в базе %d, ждали 1", n)
	}
}

// Отказ по существу не оставляет отметки в журнале: причина может отпасть (товар заведут,
// ШК освободят), и повтор после ручного разбора обязан выполниться по-настоящему.
func TestOperations_rejectionLeavesNoMark(t *testing.T) {
	pool := testutil.StartPostgres(t)
	svc := newOperationsSvc(pool)
	ctx := context.Background()

	goodA := seedGood(t, pool, "Товар A")
	goodB := seedGood(t, pool, "Товар B")
	const code = "4600000000062"
	const takenID = "eeeeeeee-1111-4111-8111-eeeeeeeeeeee"
	const conflictID = "ffffffff-1111-4111-8111-ffffffffffff"

	if _, err := svc.Apply(ctx, testUser, []service.Operation{
		opWith(takenID, repository.KindBindBarcode, map[string]any{"good_id": goodA, "barcode": code}),
	}); err != nil {
		t.Fatalf("подготовка: %v", err)
	}

	// Тот же ШК другому товару → конфликт.
	res, err := svc.Apply(ctx, testUser, []service.Operation{
		opWith(conflictID, repository.KindBindBarcode, map[string]any{"good_id": goodB, "barcode": code}),
	})
	if err != nil {
		t.Fatalf("батч с конфликтом: %v", err)
	}
	if res[0].Status != service.StatusRejected {
		t.Fatalf("ждали rejected, получили %q", res[0].Status)
	}

	var marks int
	if err := pool.QueryRow(ctx,
		`SELECT count(*) FROM processed_operations WHERE operation_id = $1::uuid`, conflictID).Scan(&marks); err != nil {
		t.Fatalf("count processed: %v", err)
	}
	if marks != 0 {
		t.Fatalf("отклонённая операция оставила %d отметок — повтор после разбора не сработает", marks)
	}
}

// Полный проход ввода остатков ЧЕРЕЗ ОЧЕРЕДЬ и повтор всего батча.
//
// Это и есть критерий P2-05, доведённый до наблюдаемого вида. Привязка ШК и строка сессии
// переживают повтор и без журнала (ON CONFLICT DO NOTHING / DO UPDATE SET — решения P-FS-02/03),
// поэтому проверять дедуп на них бессмысленно: тест прошёл бы и на коде без него. А вот ФИНАЛ
// без журнала на повторе отдаёт 409 «сессия уже закрыта» — успешная работа приезжает на
// устройство отказом и оседает на экране разбора. Здесь проверяется, что повтор получает
// исходный ответ, а остатки не пересчитываются.
func TestOperations_stockEntryReplayThroughQueue(t *testing.T) {
	pool, env := setupStockEntry(t)
	svc := newOperationsSvc(pool)
	ctx := context.Background()

	const (
		sessionID    = "5e551011-0000-4000-8000-000000000001"
		opStart      = "0a000000-0000-4000-8000-000000000001"
		opCheckpoint = "0a000000-0000-4000-8000-000000000002"
		opFinalize   = "0a000000-0000-4000-8000-000000000003"
		code         = "4600000000079"
	)

	batch := []service.Operation{
		opWith(opStart, repository.KindStockEntryStart, map[string]any{
			"session_id": sessionID, "warehouse_id": env.warehouse,
		}),
		opWith(opCheckpoint, repository.KindStockEntryCheckpoint, map[string]any{
			"session_id": sessionID,
			"cell_id":    env.cell1,
			"lines": []map[string]any{
				{"good_id": env.good1, "production_date": "14-08-2026", "qty": "12.5"},
			},
			"new_barcodes": []map[string]any{
				{"good_id": env.good1, "barcode": code, "symbology": "ean13"},
			},
		}),
		opWith(opFinalize, repository.KindStockEntryFinalize, map[string]any{"session_id": sessionID}),
	}

	first, err := svc.Apply(ctx, env.user, batch)
	if err != nil {
		t.Fatalf("первый проход батча: %v", err)
	}
	if len(first) != 3 {
		t.Fatalf("ждали 3 результата, получили %d", len(first))
	}
	for i, r := range first {
		if r.Status != service.StatusAccepted {
			t.Fatalf("операция %d: ждали accepted, получили %q (%s)", i, r.Status, r.Error)
		}
	}
	if got := writtenIn(t, first[2].Result); got != 1 {
		t.Fatalf("ответ финала: ждали written=1, получили %d (%s)", got, first[2].Result)
	}

	batchID := batchOf(t, pool, env.good1, "2026-08-14")
	want := decimal.RequireFromString("12.5")
	if got := env.qty(t, env.cell1, env.good1, batchID); !got.Equal(want) {
		t.Fatalf("остаток после первого прохода: ждали %s, получили %s", want, got)
	}

	// Ответ не дошёл до устройства — очередь шлёт весь батч заново.
	replay, err := svc.Apply(ctx, env.user, batch)
	if err != nil {
		t.Fatalf("повтор батча: %v", err)
	}
	for i, r := range replay {
		if r.Status != service.StatusDuplicate {
			t.Fatalf("повтор операции %d: ждали duplicate, получили %q (%s)", i, r.Status, r.Error)
		}
	}
	// Повтор финала обязан вернуть ИСХОДНЫЙ ответ, а не отказ «сессия уже закрыта».
	// Сравниваем разобранное значение, а не байты: ответ едет обратно через jsonb, а тот
	// пересобирает текст по-своему (пробел после двоеточия, свой порядок ключей). Для клиента
	// это тот же JSON, для strings.Compare — уже другой.
	if got := writtenIn(t, replay[2].Result); got != 1 {
		t.Fatalf("повтор финала: ждали исходное written=1, получили %d (%s)", got, replay[2].Result)
	}

	// Остаток не пересчитан и не удвоен, сессия одна, строка одна.
	if got := env.qty(t, env.cell1, env.good1, batchID); !got.Equal(want) {
		t.Fatalf("остаток после повтора: ждали %s, получили %s", want, got)
	}
	var sessions, lines int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM stock_entry_sessions`).Scan(&sessions); err != nil {
		t.Fatalf("count sessions: %v", err)
	}
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM stock_entry_lines`).Scan(&lines); err != nil {
		t.Fatalf("count lines: %v", err)
	}
	if sessions != 1 || lines != 1 {
		t.Fatalf("после повтора сессий %d, строк %d — ждали 1 и 1", sessions, lines)
	}
}
