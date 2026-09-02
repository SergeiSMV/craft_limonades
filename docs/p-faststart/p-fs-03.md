# P-FS-03 · Привязка ШК к товару и резолв товара по ШК

**Статус:** готово (ветка `p-fs-03-barcode-bind`).
**Фаза:** P-FastStart (волна 1a). ТЗ — [`p-faststart-1.md`](p-faststart-1.md).

## Задача

API штрихкодов под ввод остатков: по скану ШК определить товар, а неизвестный ШК — привязать к
выбранному из номенклатуры товару (за первый проход наполняется справочник `barcodes`).

## Критерий готовности

`GET /barcodes/{code}` → товар (200) или 404, если ШК не привязан; `POST /barcodes` привязывает ШК к
товару, повторная привязка того же ШК идемпотентна, привязка занятого ШК к другому товару → 409.
Тесты на 200/404/конфликт.

## Что сделано

- **`repository/barcode.go` — `BarcodeRepository`:**
  - `GetGoodByBarcode(code)` → `model.Good` (с именами группы/поставщика, как `GoodsRepository.GetByID`)
    или `ErrNotFound` (ШК не привязан).
  - `Bind(good_id, barcode, symbology)` — `INSERT … ON CONFLICT (barcode) DO NOTHING`; вставка была →
    ок; не было → `SELECT` владельца ШК: тот же товар → идемпотентно, другой → `ErrBarcodeConflict`;
    FK-нарушение (нет товара, SQLSTATE 23503) → `ErrGoodNotFound`; пустая `symbology` → `NULL`.
    **Аддитивно** — у товара может быть много ШК (`barcodes`: good 1→N, `UNIQUE` только на `barcode`).
- **`service/barcode.go` — `BarcodeService`:** `ResolveGood` / `Bind` с валидацией (пустые
  `good_id`/`barcode` → `ErrEmptyGoodID`/`ErrEmptyBarcode`); доменные ошибки хранилища проходят как есть.
- **`handler/barcode.go` — `BarcodeHandler`:**
  - `GET /api/v1/barcodes/{code}` → 200 товар / 404 / 400 (пустой код).
  - `POST /api/v1/barcodes` (JSON `{good_id, barcode, symbology}`) → 201 / 400 (нет полей/битый JSON)
    / 404 (нет товара) / 409 (ШК занят другим товаром).
- **Проводка:** `NewRouter(..., barcodeSvc)` — группа под `Authenticator` (**любой аутентифицированный
  сотрудник**: кладовщик привязывает ШК на проходе, решение P-FS-03, employee-доступ); `cmd/server/main.go`
  создаёт `BarcodeService`.

## Решения

- **Привязка аддитивна** — `Bind` добавляет связь `ШК→товар`, не заменяя другие ШК товара.
  Идемпотентность и конфликт — по самому ШК (`UNIQUE(barcode)`), а не по товару.
- **Резолв «нет привязки» = `ErrNotFound` → 404** — для ТСД это сигнал открыть подпоток привязки
  (P-FS-07), а не ошибка.
- **Доступ — employee** (не admin): кладовщик привязывает ШК прямо на проходе (в отличие от импорта
  справочников, оставшегося admin-only).
- **Идемпотентность vs конфликт** решаются одним `ON CONFLICT DO NOTHING` + доборным `SELECT`
  владельца — без гонок ломающих данные (низкая конкуренция на справочные ШК).

## Проверка

- Статика: `gofmt`/`go vet`/`go build`/`golangci-lint run ./...` — **0 issues**.
- Юнит (без Docker): валидация пустых `good_id`/`barcode` в `Bind`/`ResolveGood`.
- Integration (testcontainers, `service_test`): привязка+резолв (мульти-ШК: 2 ШК на товар),
  повтор идемпотентен, неизвестный ШК → `ErrNotFound`, конфликт другого товара → `ErrBarcodeConflict`
  (привязка исходного не тронута), привязка к несуществующему товару → `ErrGoodNotFound`.
- **Runtime E2E через стек** (curl, реальные nginx→backend→Postgres), все коды сошлись:
  1) без токена → **401**; 2) неизвестный ШК → **404**; 3) привязка → **201**; 4) резолв → **200**
  (вернулся товар); 5) повтор того же → **201** (идемпотентно); 6) тот же ШК другому товару → **409**;
  7) без `barcode` → **400**; 8) несуществующий товар → **404**; 9) второй ШК тому же товару → **201**.

```bash
cd apps/backend && gofmt -l internal/ cmd/ && go vet ./... && go build ./... && golangci-lint run
# integration (colima): DOCKER_HOST=unix://~/.colima/default/docker.sock TESTCONTAINERS_RYUK_DISABLED=true
go test ./internal/service/ -run TestBarcode -count=1
# runtime E2E: make up && make migrate-up && make seed → curl /api/v1/barcodes/... ; make down
```

## Границы

- Только привязка/резолв ШК. Подпоток «ШК не найден → привязать» на ТСД — **P-FS-07**. Отвязка ШК
  в MVP не предусмотрена. Композиция ввода строки остатка — **P-FS-04**.
- Генерация внутренних ШК для товаров без штрихкода (вопрос №4) — вне FastStart.
