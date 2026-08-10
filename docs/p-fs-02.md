# P-FS-02 · Атомарный SET остатка строки + GetOrCreate партии

**Статус:** готово (ветка `p-fs-02-stock-set-batch`).
**Фаза:** P-FastStart (волна 1a). ТЗ — [`docs/p-faststart-1.md`](p-faststart-1.md).

## Задача

Внутренний слой (repository + service) под запись остатков вводом:
- **партия** создаётся-или-находится по `(good_id, production_date)` без дублей;
- **остаток строки** `(ячейка × товар × партия)` приводится к заданному количеству через **SET**
  (перезапись), а не приращение; атомарно; `qty ≥ 0`.

Эндпоинт/сессия — P-FS-04; здесь только примитивы с тестами.

## Критерий готовности

Партия без дублей; SET приводит остаток строки к заданному количеству (не прибавляет);
конкурентные вызовы не ломают остаток; `qty ≥ 0`. Юнит + integration зелёные.

## Что сделано

- **`repository/batch.go` — `BatchRepository.GetOrCreate(good_id, production_date)`** → id партии.
  Идемпотентно (грань `UNIQUE(good_id, production_date)`). SQL — CTE `INSERT … ON CONFLICT DO NOTHING
  RETURNING` ∪ `SELECT существующей` `LIMIT 1`: вставляет при отсутствии, иначе возвращает
  найденную, **не трогая `updated_at`** партии на «get». Дата строкой → `$2::date`.
- **`repository/stock.go` — `StockRepository.Set(key, qty)`** + хелпер `setStock(Querier,…)`.
  Атомарный upsert `INSERT … ON CONFLICT (cell,good,batch) DO UPDATE SET qty = EXCLUDED.qty` —
  перезапись точным значением одним стейтментом. `qty` строкой → `$4::numeric`.
- **`service/stock.go` — `StockService.SetLine(key, qty)`** (+ `Set` в интерфейс `stockRepo`):
  валидирует `qty` — отрицательное → `ErrInvalidQuantity`, **ноль допустим** (напр. после Undo),
  затем `repo.Set`.

Оба низкоуровневых хелпера (`getOrCreateBatch`, `setStock`) принимают `Querier` — чтобы финал
сессии (P-FS-04) резолвил партии и писал остаток **внутри одной транзакции**.

## Решения

- **SET, а не Add** — ввод остатков фиксирует «в ячейке ровно столько» (решение B ТЗ), поэтому
  повторный checkpoint грани перезаписывает, а не удваивает.
- **Ноль допустим в `SetLine`** (в отличие от `Receive`, требующего строго положительное) — SET в 0
  осмыслен (после Undo/строка без остатка); нулевые строки не удаляем.
- **CTE get-or-create без no-op UPDATE** — «get» не должен бампать `updated_at` партии; UNION ALL +
  LIMIT 1 отдаёт вставленную либо найденную без лишней записи.
- **`Querier`-совместимость** хелперов — под транзакционную композицию в P-FS-04 (как P1-03).
- Отрицательный остаток отсекается дважды: валидацией сервиса и `CHECK(qty>=0)` в БД (страховка).

## Проверка

Статика: `gofmt` (чисто), `go vet`, `go build`, `golangci-lint run` — 0 issues.

Юнит (`internal/service`, без Docker): `SetLine` — перезапись (10→3, не 13), ноль допустим,
отрицательное отклонено (Set не вызван).

Integration (testcontainers, реальный Postgres):
- `TestBatch_GetOrCreate_idempotent` — существующая грань → та же партия; повтор → тот же id;
  другая дата → новая партия; итог 2 партии товара без дублей.
- `TestStock_Set_overwrites` — нет строки → создаётся (10.5); SET перезаписывает (→3, не 13.5);
  SET в 0 допустим.
- `TestStock_Set_negativeRejectedByCheck` — отрицательное отклоняет `CHECK(qty>=0)` БД.
- Полный прогон `repository`+`service` — зелёный, регрессий нет.

```bash
cd apps/backend
gofmt -l internal/ && go vet ./... && go build ./... && golangci-lint run
go test ./internal/service/... -count=1                 # юнит (без Docker)
# integration (colima): DOCKER_HOST=unix://~/.colima/default/docker.sock TESTCONTAINERS_RYUK_DISABLED=true
go test ./internal/repository/... ./internal/service/... -count=1
```

## Границы

- Только примитивы. Композиция «good+date → партия → SET остатка» одной транзакцией — **P-FS-04**
  (финал сессии). Привязка ШК — **P-FS-03**. Поток ТСД — **P-FS-07**.
- Внутренний склад на `stock` (ADR-0016) — вне FastStart (P4).
